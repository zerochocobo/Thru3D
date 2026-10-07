#include "rvm_backend.h"
#include "rvm_profiles.generated.h"
#include "rvm_channel_mean.h"
#include "rvm_state_guard.h"
#include "rvm_identity_tile.h"
#include <gpu.h>
#include <command.h>
#include <layer.h>
#include <cmath>
#include <chrono>
#include <cstring>
#include <mutex>
#include <stdexcept>

namespace quest {
const RvmProfile& find_profile(const std::string& key) {
    for (const auto& profile : kRvmProfiles) if (key == profile.key) return profile;
    throw std::runtime_error("Unknown RVM profile; select a verified allowlist key");
}
static std::mutex gpu_mutex;
static int gpu_users = 0;
class GpuLease final {
public:
    GpuLease() {
        std::lock_guard<std::mutex> guard(gpu_mutex);
        if (gpu_users == 0) {
            if (ncnn::create_gpu_instance() != 0) throw std::runtime_error("Vulkan instance creation failed");
            if (ncnn::get_gpu_count() < 1) {
                ncnn::destroy_gpu_instance();
                throw std::runtime_error("Vulkan device unavailable");
            }
        }
        ++gpu_users;
    }
    ~GpuLease() {
        std::lock_guard<std::mutex> guard(gpu_mutex);
        if (--gpu_users == 0) ncnn::destroy_gpu_instance();
    }
};
static std::shared_ptr<GpuLease> acquire_gpu() {
    return std::make_shared<GpuLease>();
}

void check_tensor(const ncnn::Mat& tensor, TensorShape shape) {
    if (tensor.empty() || tensor.dims != 3 || tensor.w != shape.width || tensor.h != shape.height ||
        tensor.c != shape.channels || tensor.elempack != 1 || tensor.elemsize != sizeof(float)) {
        throw std::runtime_error("RVM tensor shape/layout differs from fixed profile");
    }
    for (int channel = 0; channel < tensor.c; ++channel) {
        const float* values = tensor.channel(channel);
        for (int index = 0; index < tensor.w * tensor.h; ++index) {
            if (!std::isfinite(values[index])) throw std::runtime_error("RVM tensor is nonfinite");
        }
    }
}

#ifdef __ANDROID__
ncnn::Mat read_tensor(AAssetManager* assets, const char* path, TensorShape shape) {
    std::unique_ptr<AAsset, decltype(&AAsset_close)> asset(AAssetManager_open(assets, path, AASSET_MODE_STREAMING), AAsset_close);
    if (!asset) throw std::runtime_error("RVM fixture asset missing");
    const size_t plane = static_cast<size_t>(shape.width) * shape.height;
    if (AAsset_getLength64(asset.get()) != static_cast<int64_t>(plane * shape.channels * sizeof(float))) {
        throw std::runtime_error("RVM fixture asset size differs from tensor shape");
    }
    ncnn::Mat tensor(shape.width, shape.height, shape.channels);
    if (tensor.empty()) throw std::runtime_error("RVM tensor allocation failed");
    for (int channel = 0; channel < shape.channels; ++channel) {
        auto* destination = static_cast<unsigned char*>(static_cast<void*>(static_cast<float*>(tensor.channel(channel))));
        size_t remaining = plane * sizeof(float);
        while (remaining > 0) {
            const int count = AAsset_read(asset.get(), destination, remaining);
            if (count <= 0) throw std::runtime_error("RVM fixture read failed");
            remaining -= static_cast<size_t>(count);
            destination += count;
        }
    }
    check_tensor(tensor, shape);
    return tensor;
}

RvmBackend::RvmBackend(AAssetManager* assets, bool vulkan, const RvmProfile& profile, RvmPrecision precision)
    : profile_(profile), precision_(precision) {
    if (!assets) throw std::runtime_error("RVM asset manager unavailable");
    configure(vulkan);
    if (net_.load_param(assets, profile_.param_asset) != 0 || net_.load_model(assets, profile_.bin_asset) != 0)
        throw std::runtime_error("RVM model asset loading failed");
    reset(0); reset(1);
}
#endif

RvmBackend::RvmBackend(const char* param, const char* bin, bool vulkan, const RvmProfile& profile, RvmPrecision precision)
    : profile_(profile), precision_(precision) {
    configure(vulkan);
    if (net_.load_param(param) != 0 || net_.load_model(bin) != 0)
        throw std::runtime_error("RVM model file loading failed");
    reset(0); reset(1);
}

void RvmBackend::configure(bool vulkan) {
    if (uses_half_storage() && !vulkan) throw std::runtime_error("FP16 storage candidate requires Vulkan");
    if (vulkan) gpu_ = acquire_gpu();
    net_.opt.num_threads = 4;
    net_.opt.use_vulkan_compute = vulkan;
    net_.opt.use_fp16_packed = false;
    net_.opt.use_fp16_storage = uses_half_storage();
    net_.opt.use_fp16_arithmetic = false;
    net_.opt.use_bf16_storage = false;
    if (vulkan) {
        net_.set_vulkan_device(0);
        if (uses_half_storage() && !net_.vulkan_device()->info.support_fp16_storage())
            throw std::runtime_error("Requested FP16 Vulkan storage unavailable");
        register_rvm_channel_mean(net_);
        register_rvm_identity_tile(net_);
    }
}

class ResidentGpuState final {
public:
    const ncnn::VulkanDevice* device;
    ncnn::VkAllocator* blob;
    ncnn::VkAllocator* staging;
    StateFiniteGuard finite_guard;
    std::array<std::array<ncnn::VkMat, 4>, 2> eyes;
    explicit ResidentGpuState(const ncnn::VulkanDevice* vk, const ncnn::Option& opt) : device(vk),
        blob(nullptr), staging(nullptr), finite_guard(vk, opt) {
        blob = vk->acquire_blob_allocator(); staging = vk->acquire_staging_allocator();
        if (!blob || !staging) {
            if (blob) device->reclaim_blob_allocator(blob);
            if (staging) device->reclaim_staging_allocator(staging);
            throw std::runtime_error("RVM resident allocator unavailable");
        }
    }
    ~ResidentGpuState() {
        for (auto& eye : eyes) for (auto& state : eye) state.release();
        device->reclaim_staging_allocator(staging);
        device->reclaim_blob_allocator(blob);
    }
};

RvmBackend::~RvmBackend() = default;

void RvmBackend::reset(int eye) {
    if (eye < 0 || eye >= 2) throw std::runtime_error("RVM eye index out of range");
    std::array<ncnn::Mat, 4> next;
    for (int index = 0; index < 4; ++index) {
        const auto shape = profile_.outputs[index + 2];
        ncnn::Mat state(shape.width, shape.height, shape.channels);
        if (state.empty()) throw std::runtime_error("RVM state allocation failed");
        state.fill(0.f);
        next[index] = state;
    }
    states_[eye] = next;
    if (resident_) for (auto& state : resident_->eyes[eye]) state.release();
}

std::array<ncnn::Mat, 6> RvmBackend::infer(int eye, const ncnn::Mat& rgb) {
    if (eye < 0 || eye >= 2) throw std::runtime_error("RVM eye index out of range");
    if (resident_ && !resident_->eyes[eye][0].empty())
        throw std::runtime_error("Reset the eye before switching from resident to host-state validation");
    check_tensor(rgb, profile_.rgb);
    for (int channel = 0; channel < rgb.c; ++channel) {
        const float* values = rgb.channel(channel);
        for (int i = 0; i < rgb.w * rgb.h; ++i)
            if (values[i] < 0.f || values[i] > 1.f) throw std::runtime_error("RVM RGB outside [0,1]");
    }
    ncnn::Extractor extractor = net_.create_extractor();
    extractor.set_light_mode(false);
    if (extractor.input("in0", rgb) != 0) throw std::runtime_error("RVM RGB input failed");
    for (int index = 0; index < 4; ++index) {
        const auto name = std::string("in") + std::to_string(index + 1);
        if (extractor.input(name.c_str(), states_[eye][index]) != 0) throw std::runtime_error("RVM state input failed");
    }
    std::array<ncnn::Mat, 6> outputs;
    for (int index = 0; index < 6; ++index) {
        const auto name = std::string("out") + std::to_string(index);
        if (extractor.extract(name.c_str(), outputs[index]) != 0) throw std::runtime_error("RVM output extraction failed");
        check_tensor(outputs[index], profile_.outputs[index]);
    }
    return outputs;
}

std::array<ncnn::Mat, 4> RvmBackend::own_states(const std::array<ncnn::Mat, 6>& outputs) {
    std::array<ncnn::Mat, 4> next;
    for (int i = 0; i < 4; ++i) {
        next[i] = outputs[i + 2].clone();
        if (next[i].empty()) throw std::runtime_error("RVM owned state allocation failed");
    }
    return next;
}

std::array<ncnn::Mat, 6> RvmBackend::process(int eye, const ncnn::Mat& rgb) {
    const auto outputs = infer(eye, rgb);
    states_[eye] = own_states(outputs);
    return outputs;
}

std::array<std::array<ncnn::Mat, 6>, 2> RvmBackend::process_stereo(const std::array<ncnn::Mat, 2>& rgb) {
    std::array<std::array<ncnn::Mat, 6>, 2> outputs{{infer(0, rgb[0]), infer(1, rgb[1])}};
    const auto left = own_states(outputs[0]);
    const auto right = own_states(outputs[1]);
    states_[0] = left;
    states_[1] = right;
    return outputs;
}

static uint64_t tensor_bytes(TensorShape shape) {
    return static_cast<uint64_t>(shape.width) * shape.height * shape.channels * sizeof(float);
}

static void check_gpu_tensor(const ncnn::VkMat& tensor, TensorShape shape, bool half) {
    if (tensor.empty() || tensor.dims != 3 || tensor.w != shape.width || tensor.h != shape.height ||
        tensor.c * tensor.elempack != shape.channels ||
        tensor.elemsize != (half ? size_t(2) : sizeof(float)) * tensor.elempack)
        throw std::runtime_error("RVM resident tensor differs from requested precision/profile");
}

class ResidentPhaseClock final {
public:
    explicit ResidentPhaseClock(ResidentPhaseTiming* timing) : timing_(timing) {
        if (timing_) { *timing_ = {}; points_[0] = Clock::now(); }
    }
    void mark() {
        if (timing_) points_[++phase_] = Clock::now();
    }
    ~ResidentPhaseClock() {
        if (!timing_ || phase_ != 6) return;
        points_[7] = Clock::now();
        for (int i = 0; i < 7; ++i)
            timing_->phases_ms[i] = std::chrono::duration<double, std::milli>(points_[i+1]-points_[i]).count();
        timing_->total_ms = std::chrono::duration<double, std::milli>(points_[7]-points_[0]).count();
        timing_->completed = true;
    }
private:
    using Clock = std::chrono::steady_clock;
    ResidentPhaseTiming* timing_;
    std::array<Clock::time_point, 8> points_{};
    int phase_ = 0;
};

std::array<ncnn::Mat, 2> RvmBackend::process_alpha_stereo(const std::array<ncnn::Mat, 2>& rgb,
                                                       ResidentPhaseTiming* timing) {
    // Declared first so teardown timing also includes local command/extractor cleanup.
    ResidentPhaseClock clock(timing);
    if (!net_.opt.use_vulkan_compute) {
        const auto outputs = process_stereo(rgb);
        return {{outputs[0][1], outputs[1][1]}};
    }
    // Validate both inputs before recording any commands. Rejected input cannot
    // advance one eye or mutate a retained recurrent buffer.
    for (const auto& eye : rgb) {
        check_tensor(eye, profile_.rgb);
        for (int channel = 0; channel < eye.c; ++channel) {
            const float* values = eye.channel(channel);
            for (int i = 0; i < eye.w * eye.h; ++i)
                if (values[i] < 0.f || values[i] > 1.f) throw std::runtime_error("RVM RGB outside [0,1]");
        }
    }
    clock.mark(); // Both input validation passes completed.
    if (!resident_) resident_ = std::make_unique<ResidentGpuState>(net_.vulkan_device(), net_.opt);
    auto options = net_.opt;
    options.blob_vkallocator = resident_->blob;
    options.workspace_vkallocator = resident_->blob;
    options.staging_vkallocator = resident_->staging;
    options.use_packing_layout = false; // Downloaded Alpha is plain float32 CHW.
    ncnn::VkCompute commands(resident_->device);
    std::array<std::unique_ptr<ncnn::Extractor>, 2> extractors;
    std::array<std::array<ncnn::VkMat, 4>, 2> next;
    std::array<ncnn::Mat, 2> alpha;
    ncnn::Mat initial_flags(8), checked_flags;
    initial_flags.fill(0.f);
    ncnn::VkMat flags;
    auto flag_options = options;
    flag_options.use_fp16_packed = flag_options.use_fp16_storage = flag_options.use_fp16_arithmetic = false;
    commands.record_upload(initial_flags, flags, flag_options);
    uint64_t initial_bytes = 0;
    clock.mark(); // Allocators, command buffer and finite-flag setup.
    for (int eye = 0; eye < 2; ++eye) {
        extractors[eye] = std::make_unique<ncnn::Extractor>(net_.create_extractor());
        auto& extractor = *extractors[eye];
        extractor.set_light_mode(false);
        extractor.set_blob_vkallocator(resident_->blob);
        extractor.set_workspace_vkallocator(resident_->blob);
        extractor.set_staging_vkallocator(resident_->staging);
        ncnn::VkMat input;
        commands.record_upload(rgb[eye], input, options);
        check_gpu_tensor(input, profile_.rgb, uses_half_storage());
        if (extractor.input("in0", input) != 0) throw std::runtime_error("RVM resident RGB input failed");
        for (int index = 0; index < 4; ++index) {
            ncnn::VkMat state = resident_->eyes[eye][index];
            if (state.empty()) {
                commands.record_upload(states_[eye][index], state, options);
                initial_bytes += tensor_bytes(profile_.outputs[index + 2]);
            }
            check_gpu_tensor(state, profile_.outputs[index+2], uses_half_storage());
            if (extractor.input(("in" + std::to_string(index+1)).c_str(), state) != 0)
                throw std::runtime_error("RVM resident state input failed");
        }
        ncnn::VkMat mask;
        if (extractor.extract("out1", mask, commands) != 0) throw std::runtime_error("RVM resident Alpha extraction failed");
        check_gpu_tensor(mask, profile_.outputs[1], uses_half_storage());
        for (int index = 0; index < 4; ++index) {
            if (extractor.extract(("out" + std::to_string(index+2)).c_str(), next[eye][index], commands) != 0)
                throw std::runtime_error("RVM resident state extraction failed");
            check_gpu_tensor(next[eye][index], profile_.outputs[index+2], uses_half_storage());
            resident_->finite_guard.record(commands, next[eye][index], flags, eye*4+index);
        }
        commands.record_download(mask, alpha[eye], options);
    }
    commands.record_download(flags, checked_flags, flag_options);
    clock.mark(); // Upload/extraction/guard/download command recording.
    if (commands.submit_and_wait() != 0) throw std::runtime_error("RVM resident GPU submission failed");
    clock.mark(); // CPU wall time for submission and completion.
    if (checked_flags.empty() || checked_flags.dims != 1 || checked_flags.w != 8 || checked_flags.elempack != 1)
        throw std::runtime_error("RVM finite-state result layout invalid");
    const auto* flag_values = static_cast<const uint32_t*>(checked_flags.data);
    for (int i = 0; i < 8; ++i)
        if (flag_values[i] != 0) throw std::runtime_error("RVM recurrent state is nonfinite");
    for (const auto& mask : alpha) {
        check_tensor(mask, profile_.outputs[1]);
        const float* values = mask.channel(0);
        for (int i = 0; i < mask.w * mask.h; ++i)
            if (values[i] < 0.f || values[i] > 1.f) throw std::runtime_error("RVM Alpha outside [0,1]");
    }
    clock.mark(); // Alpha and eight state flags validated.
    resident_->eyes = next; // Commit both eyes after the submission and validation.
    transfers_.rgb_upload_bytes += 2 * tensor_bytes(profile_.rgb);
    transfers_.initial_state_upload_bytes += initial_bytes;
    transfers_.alpha_download_bytes += 2 * tensor_bytes(profile_.outputs[1]);
    transfers_.validation_upload_bytes += 8*sizeof(uint32_t);
    transfers_.validation_download_bytes += 8*sizeof(uint32_t);
    ++transfers_.committed_stereo_frames;
    clock.mark(); // Commit/accounting; final phase is local resource teardown.
    return alpha;
}

std::array<std::array<ncnn::Mat, 4>, 2> RvmBackend::snapshot_resident_states() {
    if (!resident_) throw std::runtime_error("No resident states to inspect");
    auto options = net_.opt;
    options.blob_vkallocator = resident_->blob;
    options.workspace_vkallocator = resident_->blob;
    options.staging_vkallocator = resident_->staging;
    options.use_packing_layout = false;
    ncnn::VkCompute commands(resident_->device);
    std::array<std::array<ncnn::Mat, 4>, 2> states;
    for (int eye = 0; eye < 2; ++eye) for (int index = 0; index < 4; ++index) {
        check_gpu_tensor(resident_->eyes[eye][index], profile_.outputs[index+2], uses_half_storage());
        commands.record_download(resident_->eyes[eye][index], states[eye][index], options);
    }
    if (commands.submit_and_wait() != 0) throw std::runtime_error("RVM diagnostic state readback failed");
    for (int eye = 0; eye < 2; ++eye) for (int index = 0; index < 4; ++index) {
        check_tensor(states[eye][index], profile_.outputs[index+2]);
        transfers_.diagnostic_state_download_bytes += tensor_bytes(profile_.outputs[index+2]);
    }
    return states;
}

int RvmBackend::layer_count() const { return static_cast<int>(net_.layers().size()); }
int RvmBackend::vulkan_capable_layers() const {
    int count = 0;
    for (const auto* layer : net_.layers()) if (layer->support_vulkan) ++count;
    return count;
}
std::vector<std::string> RvmBackend::non_vulkan_layers() const {
    std::vector<std::string> names;
    for (const auto* layer : net_.layers()) if (!layer->support_vulkan)
        names.push_back(layer->type + ":" + layer->name);
    return names;
}
} // namespace quest
