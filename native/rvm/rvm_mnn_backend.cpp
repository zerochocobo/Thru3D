#include "rvm_mnn_backend.h"
#include <MNN/Interpreter.hpp>
#include <MNN/MNNForwardType.h>
#include <MNN/Tensor.hpp>
#include <android/hardware_buffer.h>
#include <chrono>
#include <cmath>
#include <cstring>
#include <stdexcept>

namespace quest {
namespace {
constexpr std::array<int, 4> kStateChannels{16, 20, 40, 64}; // upstream RVM MobileNetV3; a model may declare others
// Every stride-2 stage rounds up, so state sizes are repeated ceil(x / 2).
int state_dim(int value, int level) {
    for (int i = 0; i < level; ++i) value = (value + 1) / 2;
    return value;
}
void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
} // namespace

struct MnnRvmBackend::Eye {
    MNN::Session* session = nullptr;
    MNN::Tensor* src = nullptr;
    MNN::Tensor* pha = nullptr;
    MNN::Tensor* pha_u8 = nullptr; // pha * 255 + 0.5 for the zero-copy export
    std::array<MNN::Tensor*, 4> state_in{}, state_out{};
    std::unique_ptr<MNN::Tensor> src_host, pha_host;
    std::array<std::unique_ptr<MNN::Tensor>, 4> zero_host;
};

MnnRvmBackend::MnnRvmBackend(const void* model, size_t bytes, int width, int height, bool fp16,
                             const std::string& cache_file) : cache_file_(cache_file) {
    const auto started = std::chrono::steady_clock::now();
    require(model && bytes > 0 && width >= 32 && height >= 32 && width % 2 == 0 && height % 2 == 0,
            "Invalid MNN RVM model or profile");
    report_.width = width; report_.height = height; report_.fp16 = fp16;
    net_.reset(MNN::Interpreter::createFromBuffer(model, bytes), MNN::Interpreter::destroy);
    require(net_ != nullptr, "MNN RVM model rejected");
    if (!cache_file_.empty()) net_->setCacheFile(cache_file_.c_str());
    MNN::ScheduleConfig config;
    config.type = MNN_FORWARD_OPENCL;
    config.backupType = MNN_FORWARD_CPU; // Only so placement can be audited and rejected.
    config.numThread = MNN_GPU_TUNING_WIDE | MNN_GPU_MEMORY_IMAGE;
    MNN::BackendConfig backend;
    backend.precision = fp16 ? MNN::BackendConfig::Precision_Low : MNN::BackendConfig::Precision_High;
    backend.power = MNN::BackendConfig::Power_High;
    config.backendConfig = &backend;
    for (auto& stream : eyes_) for (auto& slot : stream) {
        slot = std::make_unique<Eye>();
        auto& eye = *slot;
        eye.session = net_->createSession(config);
        require(eye.session != nullptr, "MNN OpenCL session creation failed");
        MNNForwardType main = MNN_FORWARD_CPU;
        net_->getSessionInfo(eye.session, MNN::Interpreter::BACKENDS, &main);
        require(main == MNN_FORWARD_OPENCL, "MNN OpenCL backend unavailable; refusing CPU execution");
        eye.src = net_->getSessionInput(eye.session, "src");
        require(eye.src != nullptr, "MNN RVM src input missing");
        // RGB, or RGBA (4th channel ignored; keeps MNN's 4-channel blocks aligned) when the model declares it.
        const int src_channels = eye.src->channel() == 4 ? 4 : 3;
        net_->resizeTensor(eye.src, {1, src_channels, height, width});
        for (int i = 0; i < 4; ++i) {
            const auto name = "r" + std::to_string(i + 1) + "i";
            eye.state_in[i] = net_->getSessionInput(eye.session, name.c_str());
            require(eye.state_in[i] != nullptr, "MNN RVM state input missing");
            // A model with static state channels (e.g. a slimmer decoder) declares them on its inputs.
            const int declared = eye.state_in[i]->channel();
            net_->resizeTensor(eye.state_in[i], {1, declared > 0 ? declared : kStateChannels[i],
                                                 state_dim(height, i + 1), state_dim(width, i + 1)});
        }
        net_->resizeSession(eye.session);
        eye.pha = net_->getSessionOutput(eye.session, "pha");
        require(eye.pha != nullptr && eye.pha->width() == width && eye.pha->height() == height && eye.pha->channel() == 1,
                "MNN RVM Alpha output differs from the profile");
        eye.pha_u8 = net_->getSessionOutput(eye.session, "pha_u8");
        require(eye.pha_u8 != nullptr && eye.pha_u8->width() == width && eye.pha_u8->height() == height,
                "MNN RVM model lacks the zero-copy pha_u8 output");
        for (int i = 0; i < 4; ++i) {
            const auto name = "r" + std::to_string(i + 1) + "o";
            eye.state_out[i] = net_->getSessionOutput(eye.session, name.c_str());
            const auto* in = eye.state_in[i];
            const auto* out = eye.state_out[i];
            require(out != nullptr && out->width() == in->width() && out->height() == in->height() &&
                    out->channel() == in->channel(), "MNN RVM state output differs from its input");
        }
        eye.src_host.reset(new MNN::Tensor(eye.src, MNN::Tensor::CAFFE));
        eye.pha_host.reset(new MNN::Tensor(eye.pha, MNN::Tensor::CAFFE));
        for (int i = 0; i < 4; ++i) {
            eye.zero_host[i].reset(new MNN::Tensor(eye.state_in[i], MNN::Tensor::CAFFE));
            std::memset(eye.zero_host[i]->host<float>(), 0, eye.zero_host[i]->size());
        }
        std::memset(eye.src_host->host<float>(), 0, eye.src_host->size());
    }
    for (int stream = 0; stream < kStreams; ++stream) { reset(0, stream); reset(1, stream); }
    audit_placement();
    if (!cache_file_.empty()) {
        // Persist compiled programs and tuned work sizes; a failed write only costs startup time.
        net_->updateCacheFile(eyes_[0][0]->session);
    }
    report_.prepare_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
}

MnnRvmBackend::~MnnRvmBackend() {
    for (auto& entry : shared_) { entry.second.reset(); AHardwareBuffer_release(entry.first); }
    if (net_) for (auto& stream : eyes_) for (auto& eye : stream) if (eye && eye->session) net_->releaseSession(eye->session);
}

void MnnRvmBackend::audit_placement() {
    // One run of eye 0 with zero input. Outputs are not committed, so states stay zero.
    auto& eye = *eyes_[0][0];
    eye.src->copyFromHostTensor(eye.src_host.get());
    report_.gpu_ops = 0; report_.host_ops.clear();
    const MNN::TensorCallBackWithInfo before = [](const std::vector<MNN::Tensor*>&, const MNN::OperatorInfo*) { return true; };
    const MNN::TensorCallBackWithInfo after = [this](const std::vector<MNN::Tensor*>& outputs, const MNN::OperatorInfo* info) {
        bool host = false;
        for (const auto* tensor : outputs) host |= tensor->host<void>() != nullptr;
        if (host) report_.host_ops.push_back(info->type() + ":" + info->name());
        else ++report_.gpu_ops;
        return true;
    };
    require(net_->runSessionWithCallBackInfo(eye.session, before, after, true) == MNN::NO_ERROR, "MNN RVM audit run failed");
    require(report_.gpu_ops > 0, "MNN RVM executed no OpenCL ops");
    if (!report_.host_ops.empty())
        throw std::runtime_error("MNN placed RVM ops on CPU: " + report_.host_ops.front());
}

void MnnRvmBackend::reset(int eye, int stream) {
    require(eye == 0 || eye == 1, "RVM eye index out of range");
    require(stream >= 0 && stream < kStreams, "RVM stream index out of range");
    auto& e = *eyes_[stream][eye];
    for (int i = 0; i < 4; ++i) e.state_in[i]->copyFromHostTensor(e.zero_host[i].get());
}

void MnnRvmBackend::process_alpha_stereo(const std::array<const float*, 2>& rgb, const std::array<float*, 2>& alpha,
                                         int stream, bool reset_first) {
    require(stream >= 0 && stream < kStreams, "RVM stream index out of range");
    auto& eyes = eyes_[stream];
    using Clock = std::chrono::steady_clock;
    std::array<Clock::time_point, 5> mark{};
    mark[0] = Clock::now();
    const size_t plane = static_cast<size_t>(report_.width) * report_.height;
    // Reject invalid input in either eye before any GPU work, so neither eye advances.
    for (int i = 0; i < 2; ++i) {
        require(rgb[i] != nullptr && alpha[i] != nullptr, "RVM stereo buffers missing");
        for (size_t p = 0; p < plane * 3; ++p)
            if (!(rgb[i][p] >= 0.f && rgb[i][p] <= 1.f)) throw std::runtime_error("RVM RGB outside [0,1]");
    }
    mark[1] = Clock::now();
    if (reset_first) { reset(0, stream); reset(1, stream); }
    for (int i = 0; i < 2; ++i) {
        auto& eye = *eyes[i];
        // The graph takes 0..255 (the zero-copy import is unnormalized); scale the float path to match.
        float* host = eye.src_host->host<float>();
        for (size_t p = 0; p < plane * 3; ++p) host[p] = rgb[i][p] * 255.f;
        if (eye.src->channel() == 4) std::memset(host + plane * 3, 0, plane * sizeof(float));
        eye.src->copyFromHostTensor(eye.src_host.get());
        require(net_->runSession(eye.session) == MNN::NO_ERROR, "MNN RVM inference failed");
    }
    mark[2] = Clock::now();
    for (int i = 0; i < 2; ++i) {
        auto& eye = *eyes[i];
        eye.pha->copyToHostTensor(eye.pha_host.get()); // Blocking read: completes this queue's work.
        const float* values = eye.pha_host->host<float>();
        for (size_t p = 0; p < plane; ++p)
            if (!(values[p] >= 0.f && values[p] <= 1.f)) throw std::runtime_error("RVM Alpha nonfinite or outside [0,1]");
    }
    mark[3] = Clock::now();
    // Alpha is computed from the states, so a nonfinite state surfaces in Alpha above.
    for (int i = 0; i < 2; ++i) {
        auto& eye = *eyes[i];
        std::memcpy(alpha[i], eye.pha_host->host<float>(), plane * sizeof(float));
        for (int s = 0; s < 4; ++s) eye.state_in[s]->copyFromHostTensor(eye.state_out[s]); // device -> device
    }
    mark[4] = Clock::now();
    for (int i = 0; i < 4; ++i)
        report_.last_phase_ms[i] = std::chrono::duration<double, std::milli>(mark[i + 1] - mark[i]).count();
}
} // namespace quest

namespace quest {
MNN::Tensor* MnnRvmBackend::shared(AHardwareBuffer* buffer, const MNN::Tensor* like) {
    auto& slot = shared_[buffer];
    if (!slot) {
        AHardwareBuffer_Desc desc{};
        AHardwareBuffer_describe(buffer, &desc);
        // One RGBA8 pixel holds up to four channels (MNN NC4HW4); RVM uses 3 in and 1 out.
        require(desc.format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM && desc.layers == 1 &&
                static_cast<int>(desc.width) == report_.width && static_cast<int>(desc.height) == report_.height,
                "Zero-copy AHardwareBuffer differs from the RVM profile");
        slot.reset(new MNN::Tensor(like, MNN::Tensor::CAFFE, false));
        slot->setDevicePtr(buffer, MNN_MEMORY_AHARDWAREBUFFER);
        AHardwareBuffer_acquire(buffer); // Keep the address valid while its CL import is cached.
    }
    return slot.get();
}

bool MnnRvmBackend::process_ahb(const std::array<AHardwareBuffer*, 2>& rgb, const std::array<AHardwareBuffer*, 2>& alpha,
                                int stream, bool reset_first) {
    require(stream >= 0 && stream < kStreams, "RVM stream index out of range");
    // The scout stream (1) only looks for people outside the ROI window. Both eyes of a stereo
    // frame show the same scene, so the left eye answers that at half the cost: the full scout
    // inference landed on one display frame and was the main source of dropped 8K Alpha pairs.
    const int count = stream == 1 ? 1 : 2;
    for (int i = 0; i < count; ++i) require(rgb[i] && alpha[i] && rgb[i] != alpha[i], "Zero-copy buffers missing or aliased");
    auto& eyes = eyes_[stream];
    if (reset_first) { reset(0, stream); reset(1, stream); }
    for (int i = 0; i < count; ++i) {
        auto& eye = *eyes[i];
        eye.src->copyFromHostTensor(shared(rgb[i], eye.src)); // GPU gl_to_cl import, no CPU pixels
        require(net_->runSession(eye.session) == MNN::NO_ERROR, "MNN RVM inference failed");
    }
    for (int i = 0; i < count; ++i) {
        auto& eye = *eyes[i];
        auto* out = shared(alpha[i], eye.pha_u8);
        eye.pha_u8->copyToHostTensor(out);              // GPU cl_to_gl export
        for (int s = 0; s < 4; ++s) eye.state_in[s]->copyFromHostTensor(eye.state_out[s]); // device -> device
    }
    // Both exports and state copies are on one in-order queue: finishing it publishes Alpha to GL.
    // Wait on a device tensor: a backend-less AHardwareBuffer tensor's wait() is a no-op in MNN.
    eyes[count - 1]->pha_u8->wait(MNN::Tensor::MAP_TENSOR_READ, true);
    // uint8 input cannot be nonfinite, and the export clamps NaN to 0. Recurrent states can still
    // diverge, so check the smallest one periodically instead of reading Alpha back every frame.
    if (++zero_copy_calls_[stream] % 30 != 0) return true;
    ++report_.state_checks;
    for (int i = 0; i < count; ++i) {
        auto& eye = *eyes[i];
        MNN::Tensor host(eye.state_in[3], MNN::Tensor::CAFFE);
        eye.state_in[3]->copyToHostTensor(&host);
        const float* values = host.host<float>();
        for (int p = 0; p < host.elementSize(); ++p) {
            if (!std::isfinite(values[p])) {
                reset(0, stream); reset(1, stream); ++report_.nonfinite_resets;
                return false;
            }
        }
    }
    return true;
}
} // namespace quest
