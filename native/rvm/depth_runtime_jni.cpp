// Realtime 2D->3D depth: Depth Anything V2 Small on MNN OpenCL. The render bridge stages the
// frame as float32 CHW RGB in [0, 1]; the model returns relative inverse depth (larger = nearer).
// DepthStabilizer turns it into the 0..1 near map exactly as PTMediaServer's realtime path does
// (scene cut, smoothed percentile band, VVPS base/detail stabilizer, foreground dilation).
#include "depth_stabilizer.h"
#include <MNN/Interpreter.hpp>
#include <MNN/MNNForwardType.h>
#include <MNN/Tensor.hpp>
#include <android/asset_manager.h>
#include <android/asset_manager_jni.h>
#include <sys/system_properties.h>
#include <jni.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

// MNN fork (tools/mnn/patch_mnn_vrpp.py): GPU priority of OpenCL runtimes created next on this thread.
extern "C" void vrpp_set_cl_priority(int priority);

namespace {
constexpr const char* kModelAsset = "depth-mnn/depth.mnn";

void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
void fail(JNIEnv* env, const char* message) {
    if (!env->ExceptionCheck()) {
        const auto type = env->FindClass("java/lang/IllegalStateException");
        if (type) env->ThrowNew(type, message);
    }
}
std::string text(JNIEnv* env, jstring value) {
    if (!value) return {};
    const char* chars = env->GetStringUTFChars(value, nullptr);
    require(chars != nullptr, "Depth string conversion failed");
    std::string out(chars);
    env->ReleaseStringUTFChars(value, chars);
    return out;
}

using AssetPtr = std::unique_ptr<AAsset, decltype(&AAsset_close)>;
AssetPtr open_model(JNIEnv* env, jobject assets) {
    require(assets != nullptr, "Depth model needs assets");
    AssetPtr asset(AAssetManager_open(AAssetManager_fromJava(env, assets), kModelAsset, AASSET_MODE_BUFFER), AAsset_close);
    require(asset != nullptr, "Depth model asset missing");
    require(AAsset_getBuffer(asset.get()) && AAsset_getLength64(asset.get()) > 0, "Depth model asset unreadable");
    return asset;
}
// Compiled programs belong to one graph: the cache is named after the model bytes (as RVM's).
// OpenCL memory mode. Buffers run ViT-S ~30% faster than images on Adreno 740 (MNN benchmark,
// 252x140: 37 vs 54 ms): the linear layers use the GEMM/Strassen kernels and fewer rasters.
// Debug builds can compare: adb shell setprop debug.vrpp.depth.gpumode <MNN_GPU_* bits>.
int gpu_mode() {
    int mode = MNN_GPU_TUNING_WIDE | MNN_GPU_MEMORY_BUFFER;
    char value[PROP_VALUE_MAX] = {};
    if (__system_property_get("debug.vrpp.depth.gpumode", value) > 0) {
        const int requested = std::atoi(value);
        if (requested > 0 && requested < 1024) mode = requested;
    }
    return mode;
}

// OpenCL priority of the depth queue: 0 low (default), 1 normal, 2 high.
// Debug builds can compare: adb shell setprop debug.vrpp.depth.priority low|normal|high.
int depth_priority() {
    char value[PROP_VALUE_MAX] = {};
    if (__system_property_get("debug.vrpp.depth.priority", value) > 0) {
        if (std::strcmp(value, "normal") == 0) return 1;
        if (std::strcmp(value, "high") == 0) return 2;
    }
    return 0;
}

std::string cache_path(AAsset* model, const std::string& directory) {
    if (directory.empty()) return {};
    const auto* data = static_cast<const unsigned char*>(AAsset_getBuffer(model));
    const auto bytes = static_cast<size_t>(AAsset_getLength64(model));
    uint64_t hash = 1469598103934665603ull; // FNV-1a over 8-byte words, then the tail (as RVM's cache name)
    size_t i = 0;
    for (; i + 8 <= bytes; i += 8) {
        uint64_t word;
        std::memcpy(&word, data + i, 8);
        hash = (hash ^ word) * 1099511628211ull;
    }
    for (; i < bytes; ++i) hash = (hash ^ data[i]) * 1099511628211ull;
    char tag[17];
    snprintf(tag, sizeof(tag), "%016llx", static_cast<unsigned long long>(hash));
    // Tuned kernels belong to one memory mode: each mode keeps its own cache.
    return directory + "/mnn_depth_fp16_" + tag + "_m" + std::to_string(gpu_mode()) + ".cache";
}

struct Depth final {
    std::shared_ptr<MNN::Interpreter> net;
    MNN::Session* session = nullptr;
    MNN::Tensor* src = nullptr;
    MNN::Tensor* out = nullptr;
    std::unique_ptr<MNN::Tensor> src_host, out_host;
    int width = 0, height = 0, gpu_ops = 0;
    std::vector<std::string> host_ops;
    double prepare_ms = 0, last_ms = 0, stabilize_ms = 0;
    std::unique_ptr<quest::DepthStabilizer> stabilizer;
    uint64_t frames = 0, cuts = 0;
    std::mutex operation;
    std::atomic<bool> closed{false};

    Depth(const void* model, size_t bytes, const std::string& cache) {
        const auto started = std::chrono::steady_clock::now();
        net.reset(MNN::Interpreter::createFromBuffer(model, bytes), MNN::Interpreter::destroy);
        require(net != nullptr, "MNN depth model rejected");
        if (!cache.empty()) net->setCacheFile(cache.c_str());
        MNN::ScheduleConfig config;
        config.type = MNN_FORWARD_OPENCL;
        config.backupType = MNN_FORWARD_CPU; // Only so placement can be audited and rejected.
        config.numThread = gpu_mode();
        MNN::BackendConfig backend;
        backend.precision = MNN::BackendConfig::Precision_Low;
        backend.power = MNN::BackendConfig::Power_High;
        config.backendConfig = &backend;
        // LOW GPU priority: depth runs ~70 ms at a time and must not hold back the video's GL copies.
        // At NORMAL, 1080p30 lost ~3% of frames (29.2 fps); at LOW it shows all 30 (Quest 3, measured).
        vrpp_set_cl_priority(depth_priority());
        session = net->createSession(config);
        vrpp_set_cl_priority(-1);
        require(session != nullptr, "MNN depth OpenCL session creation failed");
        MNNForwardType main = MNN_FORWARD_CPU;
        net->getSessionInfo(session, MNN::Interpreter::BACKENDS, &main);
        require(main == MNN_FORWARD_OPENCL, "MNN OpenCL backend unavailable; refusing CPU depth");
        src = net->getSessionInput(session, "src");
        out = net->getSessionOutput(session, "depth");
        require(src && out && src->channel() == 3 && src->width() > 0 && src->height() > 0, "Depth model I/O differs");
        width = src->width(); height = src->height();
        require(out->width() == width && out->height() == height, "Depth output size differs from its input");
        src_host.reset(new MNN::Tensor(src, MNN::Tensor::CAFFE));
        out_host.reset(new MNN::Tensor(out, MNN::Tensor::CAFFE));
        std::memset(src_host->host<float>(), 0, src_host->size());
        audit();
        if (!cache.empty()) net->updateCacheFile(session);
        prepare_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
    }
    ~Depth() { if (net && session) net->releaseSession(session); }

    void audit() {
        src->copyFromHostTensor(src_host.get());
        const MNN::TensorCallBackWithInfo before = [](const std::vector<MNN::Tensor*>&, const MNN::OperatorInfo*) { return true; };
        const MNN::TensorCallBackWithInfo after = [this](const std::vector<MNN::Tensor*>& outputs, const MNN::OperatorInfo* info) {
            bool host = false;
            for (const auto* tensor : outputs) host |= tensor->host<void>() != nullptr;
            if (host) host_ops.push_back(info->type() + ":" + info->name()); else ++gpu_ops;
            return true;
        };
        require(net->runSessionWithCallBackInfo(session, before, after, true) == MNN::NO_ERROR, "MNN depth audit run failed");
        require(gpu_ops > 0, "MNN depth executed no OpenCL ops");
        if (!host_ops.empty()) {
            // Every offender at once: each needs its own graph rewrite.
            std::string names;
            for (size_t i = 0; i < host_ops.size() && i < 12; ++i) names += (i ? ", " : "") + host_ops[i];
            throw std::runtime_error("MNN placed " + std::to_string(host_ops.size()) + " depth ops on CPU: " + names);
        }
    }

    /** rgb: float32 CHW in [0, 1]. near: float32 HxW in [0, 1], 1 = nearest. */
    void process(const float* rgb, float* near, bool reset, int frame_step) {
        const auto started = std::chrono::steady_clock::now();
        const size_t plane = static_cast<size_t>(width) * height;
        std::memcpy(src_host->host<float>(), rgb, plane * 3 * sizeof(float));
        src->copyFromHostTensor(src_host.get());
        require(net->runSession(session) == MNN::NO_ERROR, "MNN depth inference failed");
        out->copyToHostTensor(out_host.get()); // Blocking read completes the queue.
        if (!stabilizer) stabilizer = std::make_unique<quest::DepthStabilizer>(width, height);
        if (reset) stabilizer->reset();
        const auto inferred = std::chrono::steady_clock::now();
        stabilizer->process(out_host->host<float>(), rgb, frame_step, near);
        stabilize_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - inferred).count();
        if (stabilizer->last_cut()) ++cuts;
        ++frames;
        last_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
    }
};

std::mutex registry_mutex;
std::vector<std::pair<jlong, std::shared_ptr<Depth>>> registry;
jlong next_handle = 1;

std::shared_ptr<Depth> find(jlong handle) {
    std::lock_guard<std::mutex> guard(registry_mutex);
    for (auto& entry : registry) if (entry.first == handle && !entry.second->closed.load()) return entry.second;
    throw std::runtime_error("Depth runtime closed or unknown handle");
}
float* direct(JNIEnv* env, jobject buffer, size_t floats) {
    require(buffer && env->GetDirectBufferCapacity(buffer) == static_cast<jlong>(floats * sizeof(float)),
            "Depth requires exact-capacity direct ByteBuffers");
    auto* data = static_cast<float*>(env->GetDirectBufferAddress(buffer));
    require(data != nullptr, "Depth direct buffer inaccessible");
    return data;
}
} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_DepthNative_cachePath(JNIEnv* env, jclass, jobject assets, jstring directory) {
    try {
        const auto model = open_model(env, assets);
        return env->NewStringUTF(cache_path(model.get(), text(env, directory)).c_str());
    } catch (const std::exception& error) { fail(env, error.what()); return nullptr; }
}

extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_DepthNative_create(JNIEnv* env, jclass, jobject assets, jstring directory) {
    try {
        const auto model = open_model(env, assets);
        auto depth = std::make_shared<Depth>(AAsset_getBuffer(model.get()), static_cast<size_t>(AAsset_getLength64(model.get())),
                                             cache_path(model.get(), text(env, directory)));
        std::lock_guard<std::mutex> guard(registry_mutex);
        const jlong handle = next_handle++;
        registry.emplace_back(handle, std::move(depth));
        return handle;
    } catch (const std::exception& error) { fail(env, error.what()); return 0; }
}

extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_DepthNative_describe(JNIEnv* env, jclass, jlong handle) {
    try {
        const auto depth = find(handle);
        std::ostringstream json;
        json << "{\"width\":" << depth->width << ",\"height\":" << depth->height << ",\"gpu_mode\":" << gpu_mode() << ",\"priority\":" << depth_priority() << ",\"prepare_ms\":" << depth->prepare_ms
             << ",\"gpu_ops\":" << depth->gpu_ops << ",\"cpu_fallback_ops\":" << depth->host_ops.size() << '}';
        return env->NewStringUTF(json.str().c_str());
    } catch (const std::exception& error) { fail(env, error.what()); return nullptr; }
}

extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_DepthNative_process(JNIEnv* env, jclass, jlong handle, jobject rgb, jobject near,
                                                       jboolean reset, jint frameStep) {
    try {
        const auto depth = find(handle);
        std::unique_lock<std::mutex> guard(depth->operation, std::try_to_lock);
        require(guard.owns_lock(), "Depth runtime busy; no requests queued");
        const size_t plane = static_cast<size_t>(depth->width) * depth->height;
        const float* input = direct(env, rgb, plane * 3);
        float* output = direct(env, near, plane);
        for (size_t p = 0; p < plane * 3; ++p)
            if (!(input[p] >= 0.f && input[p] <= 1.f)) throw std::runtime_error("Depth RGB outside [0,1]");
        depth->process(input, output, reset == JNI_TRUE, frameStep < 1 ? 1 : frameStep);
        std::ostringstream json;
        json << "{\"state\":\"" << (depth->closed.load() ? "stale" : "ready") << "\",\"depth_ms\":" << depth->last_ms
             << ",\"stabilize_ms\":" << depth->stabilize_ms << ",\"shift_x\":" << depth->stabilizer->last_dx() << ",\"shift_y\":" << depth->stabilizer->last_dy()
             << ",\"frames\":" << depth->frames
             << ",\"cuts\":" << depth->cuts << '}';
        return env->NewStringUTF(json.str().c_str());
    } catch (const std::exception& error) { fail(env, error.what()); return nullptr; }
}

extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_DepthNative_close(JNIEnv*, jclass, jlong handle) {
    std::shared_ptr<Depth> released; // An in-flight process keeps its own reference.
    std::lock_guard<std::mutex> guard(registry_mutex);
    for (auto it = registry.begin(); it != registry.end(); ++it) if (it->first == handle) {
        released = it->second; released->closed.store(true); registry.erase(it); break;
    }
}
