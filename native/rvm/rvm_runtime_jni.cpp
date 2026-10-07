#include "rvm_backend.h"
#include "rvm_mnn_backend.h"
#include <android/hardware_buffer.h>
#include "rvm_profiles.generated.h"
#include <android/asset_manager_jni.h>
#include <jni.h>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <unordered_map>
#include <vector>

namespace {
std::atomic<int> live_instances{0};
struct LiveInstance final {
    LiveInstance() { ++live_instances; }
    ~LiveInstance() { --live_instances; }
};
struct AssetLease final {
    JavaVM* vm = nullptr;
    jobject assets_owner = nullptr;
    AssetLease(JNIEnv* env, jobject assets) {
        if (env->GetJavaVM(&vm) != JNI_OK) throw std::runtime_error("RVM Java VM unavailable");
        assets_owner = env->NewGlobalRef(assets);
        if (!assets_owner) throw std::runtime_error("RVM asset lifetime retention failed");
    }
    ~AssetLease() {
        JNIEnv* env = nullptr;
        bool attached = false;
        if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) == JNI_EDETACHED)
            attached = vm->AttachCurrentThread(&env, nullptr) == JNI_OK;
        if (env) env->DeleteGlobalRef(assets_owner);
        if (attached) vm->DetachCurrentThread();
    }
};
std::mutex config_mutex;
std::string cache_directory; // config_mutex
bool gpu_fp16 = true;        // config_mutex
std::string gpu_model = "fast"; // config_mutex: model of GPU runtimes prepared from now on

// "fast": distilled narrow-decoder RVM (default); "quality": the fused upstream network.
const char* model_asset(const std::string& model) {
    if (model == "fast") return "rvm-mnn/rvm.mnn";
#if QUEST_DIAGNOSTIC_MODELS
    if (model == "quality") return "rvm-mnn/rvm_quality.mnn";
#endif
    throw std::runtime_error("Unknown RVM model: " + model);
}
std::string current_model() {
    std::lock_guard<std::mutex> guard(config_mutex);
    return gpu_model;
}

using AssetPtr = std::unique_ptr<AAsset, decltype(&AAsset_close)>;
AssetPtr open_mnn_model(AAssetManager* assets, const std::string& model) {
    AssetPtr asset(AAssetManager_open(assets, model_asset(model), AASSET_MODE_BUFFER), AAsset_close);
    if (!asset) throw std::runtime_error("MNN RVM model asset missing");
    if (!AAsset_getBuffer(asset.get()) || AAsset_getLength64(asset.get()) <= 0) throw std::runtime_error("MNN RVM model asset unreadable");
    return asset;
}

// Compiled programs and tuned work sizes belong to one graph: name the cache after the model
// bytes, so an updated model never loads another graph's tuning.
std::string mnn_cache_path(AAsset* model, const quest::RvmProfile& profile, bool fp16) {
    const auto* data = static_cast<const unsigned char*>(AAsset_getBuffer(model));
    const auto bytes = static_cast<size_t>(AAsset_getLength64(model));
    uint64_t hash = 1469598103934665603ull; // FNV-1a over 8-byte words, then the tail
    size_t i = 0;
    for (; i + 8 <= bytes; i += 8) {
        uint64_t word;
        std::memcpy(&word, data + i, 8);
        hash = (hash ^ word) * 1099511628211ull;
    }
    for (; i < bytes; ++i) hash = (hash ^ data[i]) * 1099511628211ull;
    char tag[17];
    snprintf(tag, sizeof(tag), "%016llx", static_cast<unsigned long long>(hash));
    std::lock_guard<std::mutex> guard(config_mutex);
    if (cache_directory.empty()) return {};
    return cache_directory + "/mnn_rvm_" + profile.key + (fp16 ? "_fp16_" : "_fp32_") + tag + ".cache";
}

// GPU runtimes use MNN OpenCL (ratio=1 upstream branch, pha + states, one dynamic model).
std::unique_ptr<quest::MnnRvmBackend> make_mnn(AAssetManager* assets, const quest::RvmProfile& profile,
                                               const std::string& model) {
    const auto asset = open_mnn_model(assets, model);
    bool fp16;
    {
        std::lock_guard<std::mutex> guard(config_mutex);
        fp16 = gpu_fp16;
    }
    const auto cache = mnn_cache_path(asset.get(), profile, fp16);
    return std::make_unique<quest::MnnRvmBackend>(AAsset_getBuffer(asset.get()), static_cast<size_t>(AAsset_getLength64(asset.get())),
                                                  profile.rgb.width, profile.rgb.height, fp16, cache);
}

struct Runtime final {
    // Release backend/GPU first, asset owner second, live-instance lease last.
    LiveInstance live;
    AssetLease assets_owner;
    std::mutex operation;
    std::atomic<bool> closed{false};
    std::atomic<jlong> generation;
    jlong applied_generation;
    const jlong session;
    // Per stream: 0 display, 1 ROI scout (same frame may run on both streams).
    std::array<jlong, 2> last_frame{{-1, -1}};
    std::array<jlong, 2> last_pts{{-1, -1}};
    const quest::RvmProfile& profile;
    std::unique_ptr<quest::RvmBackend> cpu;     // ncnn CPU reference path
    std::unique_ptr<quest::MnnRvmBackend> gpu;  // MNN OpenCL production path
    std::array<std::vector<float>, 2> alpha;
    Runtime(JNIEnv* env, jobject assets, bool use_gpu, const quest::RvmProfile& selected, jlong id, jlong gen)
        : assets_owner(env, assets), generation(gen), applied_generation(gen), session(id), profile(selected) {
        auto* manager = AAssetManager_fromJava(env, assets);
#if !QUEST_DIAGNOSTIC_MODELS
        if (!use_gpu) throw std::runtime_error("CPU RVM is available only in the diagnostic build");
#endif
        if (use_gpu) gpu = make_mnn(manager, profile, current_model());
        else cpu = std::make_unique<quest::RvmBackend>(manager, false, profile);
        const size_t plane = static_cast<size_t>(profile.rgb.width) * profile.rgb.height;
        alpha[0].resize(plane);
        alpha[1].resize(plane);
    }
    void reset() {
        if (gpu) { gpu->reset(0); gpu->reset(1); }
        else { cpu->reset(0); cpu->reset(1); }
    }
};
std::mutex registry_mutex;
std::unordered_map<jlong, std::shared_ptr<Runtime>> registry;
jlong next_handle = 1;

void fail(JNIEnv* env, const char* message) {
    if (!env->ExceptionCheck()) {
        const auto type = env->FindClass("java/lang/IllegalStateException");
        if (type) env->ThrowNew(type, message);
    }
}
std::shared_ptr<Runtime> instance(jlong handle) {
    std::lock_guard<std::mutex> guard(registry_mutex);
    const auto found = registry.find(handle);
    if (found == registry.end() || found->second->closed.load()) throw std::runtime_error("RVM runtime closed or unknown handle");
    return found->second;
}
std::string key_from_java(JNIEnv* env, jstring key) {
    if (!key) throw std::runtime_error("RVM profile missing");
    const char* chars = env->GetStringUTFChars(key, nullptr);
    if (!chars) throw std::runtime_error("RVM profile conversion failed");
    const std::string value(chars);
    env->ReleaseStringUTFChars(key, chars);
    return value;
}
struct Buffer { unsigned char* address; size_t bytes; };
Buffer direct(JNIEnv* env, jobject buffer, size_t bytes, bool writable = false) {
    if (!buffer || env->GetDirectBufferCapacity(buffer) != static_cast<jlong>(bytes))
        throw std::runtime_error("RVM requires exact-capacity direct ByteBuffers");
    auto* data = static_cast<unsigned char*>(env->GetDirectBufferAddress(buffer));
    if (!data) throw std::runtime_error("RVM direct buffer inaccessible");
    if (writable) {
        const auto type = env->GetObjectClass(buffer);
        const auto method = type ? env->GetMethodID(type, "isReadOnly", "()Z") : nullptr;
        const bool readonly = method && env->CallBooleanMethod(buffer, method) == JNI_TRUE;
        if (type) env->DeleteLocalRef(type);
        if (!method || env->ExceptionCheck() || readonly) throw std::runtime_error("RVM output ByteBuffer is not writable");
    }
    return {data, bytes};
}
void distinct(const std::array<Buffer, 4>& buffers) {
    for (size_t i = 0; i < buffers.size(); ++i) for (size_t j = i + 1; j < buffers.size(); ++j) {
        const auto a = reinterpret_cast<uintptr_t>(buffers[i].address);
        const auto b = reinterpret_cast<uintptr_t>(buffers[j].address);
        if ((a <= b && b - a < buffers[i].bytes) || (b < a && a - b < buffers[j].bytes))
            throw std::runtime_error("RVM input/output buffers overlap");
    }
}
ncnn::Mat copy_rgb(Buffer source, quest::TensorShape shape) {
    ncnn::Mat rgb(shape.width, shape.height, shape.channels);
    if (rgb.empty()) throw std::runtime_error("RVM RGB allocation failed");
    const size_t plane_bytes = static_cast<size_t>(shape.width) * shape.height * sizeof(float);
    for (int channel = 0; channel < shape.channels; ++channel)
        std::memcpy(static_cast<float*>(rgb.channel(channel)), source.address + channel * plane_bytes, plane_bytes);
    return rgb;
}
} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_RvmNative_runtimeCapabilities(JNIEnv* env, jclass) {
    try {
        std::ostringstream json;
        bool fp16;
        { std::lock_guard<std::mutex> guard(config_mutex); fp16 = gpu_fp16; }
        json << "{\"schema_version\":2,\"gpu_backend\":\"MNN_3.6.1_OpenCL\",\"cpu_backend\":\"ncnn\","
             << "\"cpu_available\":" << (QUEST_DIAGNOSTIC_MODELS ? "true" : "false") << ','
             << "\"gpu_precision\":\"" << (fp16 ? "fp16" : "fp32") << "\",\"gpu_model\":\"ratio1_upstream_pha_states\","
             << "\"state_storage\":\"backend_dependent\",\"cpu_state_storage\":\"host_fp32\","
             << "\"gpu_state_storage\":\"MNN_OpenCL_device\",\"gpu_cpu_fallback_ops_allowed\":false,"
             << "\"layout\":\"little-endian float32 CHW\","
             << "\"max_instances\":1,\"video_integrated\":false,\"device_tested\":false,\"profiles\":[";
        for (size_t i = 0; i < quest::kRvmProfiles.size(); ++i) {
            const auto& p = quest::kRvmProfiles[i];
            if (i) json << ',';
            json << "{\"key\":\"" << p.key << "\",\"width\":" << p.rgb.width
                 << ",\"height\":" << p.rgb.height << '}';
        }
        json << "]}";
        return env->NewStringUTF(json.str().c_str());
    } catch (const std::exception& error) { fail(env, error.what()); return nullptr; }
}

extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_RvmNative_prepareRuntime(JNIEnv* env, jclass, jobject assets, jboolean vulkan,
                                                           jstring key, jlong session, jlong generation) {
    try {
        if (!assets || session <= 0 || generation <= 0) throw std::runtime_error("RVM requires positive session/generation and assets");
        const auto& profile = quest::find_profile(key_from_java(env, key));
        std::lock_guard<std::mutex> guard(registry_mutex);
        if (!registry.empty() || live_instances.load() != 0)
            throw std::runtime_error("Close the active runtime and finish its in-flight operation before preparing another");
        if (next_handle == std::numeric_limits<jlong>::max()) throw std::runtime_error("RVM handle space exhausted");
        auto runtime = std::make_shared<Runtime>(env, assets, vulkan == JNI_TRUE, profile, session, generation);
        const auto handle = next_handle++;
        registry.emplace(handle, std::move(runtime));
        return handle;
    } catch (const std::exception& error) { fail(env, error.what()); return 0; }
}

extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RvmNative_resetRuntime(JNIEnv* env, jclass, jlong handle, jlong next_generation) {
    try {
        const auto runtime = instance(handle);
        jlong previous = runtime->generation.load();
        do {
            if (next_generation <= previous) throw std::runtime_error("RVM reset requires a strictly newer generation");
        } while (!runtime->generation.compare_exchange_weak(previous, next_generation));
        // Invalidate old results immediately, then wait for this one bounded in-flight call.
        std::lock_guard<std::mutex> guard(runtime->operation);
        if (runtime->closed.load() || runtime->generation.load() != next_generation) return JNI_FALSE;
        try { runtime->reset(); }
        catch (...) { runtime->closed.store(true); throw; }
        runtime->last_frame = {{-1, -1}};
        runtime->last_pts = {{-1, -1}};
        runtime->applied_generation = next_generation;
        return runtime->closed.load() || runtime->generation.load() != next_generation ? JNI_FALSE : JNI_TRUE;
    } catch (const std::exception& error) { fail(env, error.what()); return JNI_FALSE; }
}

static jstring process(JNIEnv* env, jlong handle, jlong generation, jlong frame, jlong pts, jobject left, jobject right,
                jobject left_alpha, jobject right_alpha, int stream, bool reset_first) {
    try {
        if (stream < 0 || stream > 1) throw std::runtime_error("RVM stream must be 0 (display) or 1 (scout)");
        const auto runtime = instance(handle);
        std::unique_lock<std::mutex> guard(runtime->operation, std::try_to_lock);
        if (!guard.owns_lock()) throw std::runtime_error("RVM runtime busy; no requests queued");
        if (runtime->closed.load() || generation != runtime->generation.load() || generation != runtime->applied_generation)
            throw std::runtime_error("RVM obsolete generation");
        if (stream != 0 && !runtime->gpu) throw std::runtime_error("RVM scout stream requires the GPU runtime");
        if (frame < 0 || frame <= runtime->last_frame[stream] || pts < 0 || pts < runtime->last_pts[stream])
            throw std::runtime_error("RVM nonmonotonic frame identity/PTS; reset on discontinuity");
        const auto shape = runtime->profile.rgb;
        const size_t alpha_bytes = static_cast<size_t>(shape.width) * shape.height * sizeof(float);
        std::array<Buffer, 4> buffers{{direct(env, left, alpha_bytes * 3), direct(env, right, alpha_bytes * 3),
                                     direct(env, left_alpha, alpha_bytes, true), direct(env, right_alpha, alpha_bytes, true)}};
        distinct(buffers);
        if (runtime->gpu) {
            runtime->gpu->process_alpha_stereo(
                {{reinterpret_cast<const float*>(buffers[0].address), reinterpret_cast<const float*>(buffers[1].address)}},
                {{runtime->alpha[0].data(), runtime->alpha[1].data()}}, stream, reset_first);
        } else {
            if (reset_first) runtime->reset();
            const auto outputs = runtime->cpu->process_alpha_stereo({{copy_rgb(buffers[0], shape), copy_rgb(buffers[1], shape)}});
            for (int eye = 0; eye < 2; ++eye)
                std::memcpy(runtime->alpha[eye].data(), static_cast<const float*>(outputs[eye].channel(0)), alpha_bytes);
        }
        // Results are written to the caller only for a still-current generation.
        if (runtime->closed.load() || runtime->generation.load() != generation)
            return env->NewStringUTF("{\"state\":\"stale\"}");
        std::memcpy(buffers[2].address, runtime->alpha[0].data(), alpha_bytes);
        std::memcpy(buffers[3].address, runtime->alpha[1].data(), alpha_bytes);
        runtime->last_frame[stream] = frame;
        runtime->last_pts[stream] = pts;
        std::ostringstream json;
        json << "{\"state\":\"ready\",\"session_id\":" << runtime->session << ",\"generation\":" << generation
             << ",\"frame_id\":" << frame << ",\"pts_us\":" << pts << ",\"profile_key\":\""
             << runtime->profile.key << "\",\"source_pts_verified\":false,\"video_integrated\":false,"
             << "\"stream\":" << stream << ",\"reset_first\":" << (reset_first ? "true" : "false") << ',';
        if (runtime->gpu) {
            const auto& r = runtime->gpu->report();
            json << "\"backend\":\"MNN_OpenCL\",\"precision\":\"" << (r.fp16 ? "fp16" : "fp32")
                 << "\",\"state_storage\":\"MNN_OpenCL_device\",\"gpu_ops\":" << r.gpu_ops
                 << ",\"cpu_fallback_ops\":" << r.host_ops.size() << ",\"prepare_ms\":" << r.prepare_ms << '}';
            return env->NewStringUTF(json.str().c_str());
        }
        const auto& transfers = runtime->cpu->transfer_stats();
        json << "\"backend\":\"ncnn_cpu\",\"state_storage\":\"host_fp32"
             << "\",\"explicit_gpu_transfer_totals\":{\"rgb_upload_bytes\":" << transfers.rgb_upload_bytes
             << ",\"initial_state_upload_bytes\":" << transfers.initial_state_upload_bytes
             << ",\"alpha_download_bytes\":" << transfers.alpha_download_bytes
             << ",\"validation_upload_bytes\":" << transfers.validation_upload_bytes
             << ",\"validation_download_bytes\":" << transfers.validation_download_bytes
             << ",\"committed_stereo_frames\":" << transfers.committed_stereo_frames
             << ",\"diagnostic_state_download_bytes\":" << transfers.diagnostic_state_download_bytes
             << "},\"internal_ncnn_transfer_traffic_measured\":false}";
        return env->NewStringUTF(json.str().c_str());
    } catch (const std::exception& error) { fail(env, error.what()); return nullptr; }
}

extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_RvmNative_processRuntime(JNIEnv* env, jclass, jlong handle, jlong generation,
    jlong frame, jlong pts, jobject left, jobject right, jobject left_alpha, jobject right_alpha) {
    return process(env, handle, generation, frame, pts, left, right, left_alpha, right_alpha, 0, false);
}

extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_RvmNative_processRuntimeStream(JNIEnv* env, jclass, jlong handle, jlong generation,
    jlong frame, jlong pts, jobject left, jobject right, jobject left_alpha, jobject right_alpha, jint stream, jboolean reset_first) {
    return process(env, handle, generation, frame, pts, left, right, left_alpha, right_alpha, stream, reset_first == JNI_TRUE);
}

extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RvmNative_closeRuntime(JNIEnv*, jclass, jlong handle) {
    // shared_ptr retains any in-flight operation; callers reject its output after close.
    std::shared_ptr<Runtime> released;
    {
        std::lock_guard<std::mutex> guard(registry_mutex);
        const auto found = registry.find(handle);
        if (found == registry.end()) return;
        released = found->second;
        released->closed.store(true);
        registry.erase(found);
    }
}

extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RvmNative_configureGpu(JNIEnv* env, jclass, jstring directory, jboolean fp16) {
    try {
        std::string path;
        if (directory) path = key_from_java(env, directory);
        std::lock_guard<std::mutex> guard(config_mutex);
        cache_directory = path;
        gpu_fp16 = fp16 == JNI_TRUE;
    } catch (const std::exception& error) { fail(env, error.what()); }
}

// Model of GPU runtimes prepared from now on; a running runtime keeps its model.
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RvmNative_selectGpuModel(JNIEnv* env, jclass, jstring model) {
    try {
        const auto name = key_from_java(env, model);
        model_asset(name);
        std::lock_guard<std::mutex> guard(config_mutex);
        gpu_model = name;
    } catch (const std::exception& error) { fail(env, error.what()); }
}

// Cache file the GPU runtime of this profile and model reads and writes (empty without a cache directory).
extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_RvmNative_gpuCachePath(JNIEnv* env, jclass, jobject assets, jstring key, jstring model) {
    try {
        if (!assets) throw std::runtime_error("RVM cache path requires assets");
        const auto& profile = quest::find_profile(key_from_java(env, key));
        const auto asset = open_mnn_model(AAssetManager_fromJava(env, assets), key_from_java(env, model));
        bool fp16;
        {
            std::lock_guard<std::mutex> guard(config_mutex);
            fp16 = gpu_fp16;
        }
        return env->NewStringUTF(mnn_cache_path(asset.get(), profile, fp16).c_str());
    } catch (const std::exception& error) { fail(env, error.what()); return nullptr; }
}

// Builds and discards one MNN OpenCL backend so its compiled programs and tuned work
// sizes reach the cache before playback. Not a runtime: never touches the registry.
extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_RvmNative_warmupGpu(JNIEnv* env, jclass, jobject assets, jstring key, jstring model) {
    try {
        if (!assets) throw std::runtime_error("RVM warmup requires assets");
        const auto& profile = quest::find_profile(key_from_java(env, key));
        const auto backend = make_mnn(AAssetManager_fromJava(env, assets), profile, key_from_java(env, model));
        std::ostringstream json;
        json << "{\"profile_key\":\"" << profile.key << "\",\"prepare_ms\":" << backend->report().prepare_ms
             << ",\"gpu_ops\":" << backend->report().gpu_ops << '}';
        return env->NewStringUTF(json.str().c_str());
    } catch (const std::exception& error) { fail(env, error.what()); return nullptr; }
}

// Zero-copy display stream: AHardwareBuffer handles come from the render bridge, whose slot lease
// keeps them alive for this call. Alpha lands in the output buffers; nothing returns to the CPU.
extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_RvmNative_processRuntimeAhb(JNIEnv* env, jclass, jlong handle, jlong generation,
    jlong frame, jlong pts, jlong left, jlong right, jlong left_alpha, jlong right_alpha, jint stream, jboolean reset_first) {
    try {
        if (stream < 0 || stream > 1) throw std::runtime_error("RVM stream must be 0 (display) or 1 (scout)");
        const auto runtime = instance(handle);
        std::unique_lock<std::mutex> guard(runtime->operation, std::try_to_lock);
        if (!guard.owns_lock()) throw std::runtime_error("RVM runtime busy; no requests queued");
        if (!runtime->gpu) throw std::runtime_error("Zero-copy RVM requires the GPU runtime");
        if (runtime->closed.load() || generation != runtime->generation.load() || generation != runtime->applied_generation)
            throw std::runtime_error("RVM obsolete generation");
        if (frame < 0 || frame <= runtime->last_frame[stream] || pts < 0 || pts < runtime->last_pts[stream])
            throw std::runtime_error("RVM nonmonotonic frame identity/PTS; reset on discontinuity");
        auto buffer = [](jlong value) { return reinterpret_cast<AHardwareBuffer*>(static_cast<uintptr_t>(value)); };
        const bool healthy = runtime->gpu->process_ahb({{buffer(left), buffer(right)}}, {{buffer(left_alpha), buffer(right_alpha)}},
                                                       stream, reset_first == JNI_TRUE);
        if (runtime->closed.load() || runtime->generation.load() != generation)
            return env->NewStringUTF("{\"state\":\"stale\"}");
        runtime->last_frame[stream] = frame;
        runtime->last_pts[stream] = pts;
        const auto& r = runtime->gpu->report();
        std::ostringstream json;
        json << "{\"state\":\"" << (healthy ? "ready" : "state_reset") << "\",\"session_id\":" << runtime->session
             << ",\"generation\":" << generation << ",\"frame_id\":" << frame << ",\"pts_us\":" << pts
             << ",\"profile_key\":\"" << runtime->profile.key << "\",\"stream\":" << stream
             << ",\"reset_first\":" << (reset_first == JNI_TRUE ? "true" : "false")
             << ",\"backend\":\"MNN_OpenCL\",\"precision\":\"" << (r.fp16 ? "fp16" : "fp32")
             << "\",\"transport\":\"AHardwareBuffer_zero_copy\",\"gpu_ops\":" << r.gpu_ops
             << ",\"cpu_fallback_ops\":" << r.host_ops.size() << ",\"state_checks\":" << r.state_checks
             << ",\"nonfinite_resets\":" << r.nonfinite_resets << '}';
        return env->NewStringUTF(json.str().c_str());
    } catch (const std::exception& error) { fail(env, error.what()); return nullptr; }
}

// ROI analysis input: copy the R channel (round(alpha*255)) of two zero-copy Alpha buffers into
// one direct buffer, left plane then right. Call only after the inference that wrote them returned.
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_RvmNative_readAlphaPlanes(JNIEnv* env, jclass, jlong left, jlong right, jobject output) {
    try {
        std::array<AHardwareBuffer*, 2> buffers{{reinterpret_cast<AHardwareBuffer*>(static_cast<uintptr_t>(left)),
                                                reinterpret_cast<AHardwareBuffer*>(static_cast<uintptr_t>(right))}};
        if (!buffers[0] || !buffers[1]) throw std::runtime_error("Alpha planes need two buffers");
        AHardwareBuffer_Desc desc{};
        AHardwareBuffer_describe(buffers[0], &desc);
        const size_t plane = static_cast<size_t>(desc.width) * desc.height;
        auto* target = static_cast<unsigned char*>(direct(env, output, plane * 2, true).address);
        for (int eye = 0; eye < 2; ++eye) {
            AHardwareBuffer_Desc current{};
            AHardwareBuffer_describe(buffers[eye], &current);
            if (current.width != desc.width || current.height != desc.height || current.format != AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM)
                throw std::runtime_error("Alpha plane buffers differ");
            void* address = nullptr;
            if (AHardwareBuffer_lock(buffers[eye], AHARDWAREBUFFER_USAGE_CPU_READ_RARELY, -1, nullptr, &address) != 0 || !address)
                throw std::runtime_error("Alpha plane lock failed");
            // The buffer is uncached for the CPU: copy whole rows with wide loads, then pick R.
            const auto* rgba = static_cast<const unsigned char*>(address);
            std::vector<uint32_t> row(desc.width);
            for (uint32_t y = 0; y < desc.height; ++y) {
                std::memcpy(row.data(), rgba + static_cast<size_t>(y) * current.stride * 4, desc.width * 4);
                auto* out = target + eye * plane + static_cast<size_t>(y) * desc.width;
                for (uint32_t x = 0; x < desc.width; ++x) out[x] = static_cast<unsigned char>(row[x] & 0xff); // little-endian R
            }
            AHardwareBuffer_unlock(buffers[eye], nullptr);
        }
        return JNI_TRUE;
    } catch (const std::exception& error) { fail(env, error.what()); return JNI_FALSE; }
}
