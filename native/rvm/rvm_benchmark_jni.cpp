#include "rvm_backend.h"
#include <android/asset_manager_jni.h>
#include <android/log.h>
#include <jni.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <iomanip>
#include <sstream>
#include <stdexcept>

namespace {
std::atomic<int> generation{0};
constexpr const char* output_names[] = {"fgr", "pha", "r1o", "r2o", "r3o", "r4o"};
struct Error { double maximum = 0; double rms = 0; };

Error difference(const ncnn::Mat& actual, const ncnn::Mat& expected) {
    double sum = 0;
    Error error;
    for (int channel = 0; channel < actual.c; ++channel) {
        const float* a = actual.channel(channel);
        const float* b = expected.channel(channel);
        for (int index = 0; index < actual.w * actual.h; ++index) {
            const double delta = std::abs(static_cast<double>(a[index]) - b[index]);
            error.maximum = std::max(error.maximum, delta);
            sum += delta * delta;
        }
    }
    error.rms = std::sqrt(sum / (actual.w * actual.h * actual.c));
    return error;
}

std::string benchmark(AAssetManager* assets, bool vulkan, int id, const quest::RvmProfile& profile) {
    if (!assets) throw std::runtime_error("Asset manager unavailable");
    if (generation.load() != id) return "{\"state\":\"cancelled\"}";
    quest::RvmBackend backend(assets, vulkan, profile);
    using Outputs = std::array<ncnn::Mat, 6>;
    std::array<std::array<ncnn::Mat, 2>, 2> inputs;
    std::array<std::array<Outputs, 2>, 2> reference;
    std::array<std::array<Outputs, 2>, 2> actual;
    for (int eye = 0; eye < 2; ++eye) {
        for (int frame = 0; frame < 2; ++frame) {
            const std::string prefix = std::string(profile.oracle_prefix) + (eye == 0 ? "left_" : "right_") + std::to_string(frame);
            inputs[eye][frame] = quest::read_tensor(assets, (prefix + ".src.f32").c_str(), profile.rgb);
            for (int output = 0; output < 6; ++output) {
                reference[eye][frame][output] = quest::read_tensor(assets,
                    (prefix + "." + output_names[output] + ".f32").c_str(), profile.outputs[output]);
            }
        }
    }
    std::array<Error, 6> errors;
    std::vector<double> timings;
    // Interleave both eyes and verify complete recurrent outputs, not only Alpha.
    for (int frame = 0; frame < 2; ++frame) {
        for (int eye = 0; eye < 2; ++eye) {
            if (generation.load() != id) return "{\"state\":\"cancelled\"}";
            const auto begin = std::chrono::steady_clock::now();
            actual[eye][frame] = backend.process(eye, inputs[eye][frame]);
            timings.push_back(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - begin).count());
            for (int output = 0; output < 6; ++output) {
                const auto error = difference(actual[eye][frame][output], reference[eye][frame][output]);
                errors[output].maximum = std::max(errors[output].maximum, error.maximum);
                errors[output].rms = std::max(errors[output].rms, error.rms);
            }
        }
    }
    double isolation_error = 0;
    for (int eye = 0; eye < 2; ++eye) {
        backend.reset(eye);
        for (int frame = 0; frame < 2; ++frame) {
            if (generation.load() != id) return "{\"state\":\"cancelled\"}";
            const auto isolated = backend.process(eye, inputs[eye][frame]);
            for (int output = 0; output < 6; ++output) {
                isolation_error = std::max(isolation_error, difference(isolated[output], actual[eye][frame][output]).maximum);
            }
        }
    }
    // Reset left; subsequent right must equal an unchanged right sequence.
    const auto right_next = backend.process(1, inputs[1][1]);
    backend.reset(1);
    backend.process(1, inputs[1][0]);
    backend.process(1, inputs[1][1]);
    backend.reset(0);
    const auto reset_left = backend.process(0, inputs[0][0]);
    const auto right_after_left_reset = backend.process(1, inputs[1][1]);
    double reset_error = 0;
    for (int output = 0; output < 6; ++output) {
        reset_error = std::max(reset_error, difference(reset_left[output], actual[0][0][output]).maximum);
        reset_error = std::max(reset_error, difference(right_next[output], right_after_left_reset[output]).maximum);
    }
    bool numerical = true;
    for (int output = 0; output < 6; ++output) {
        if (errors[output].maximum > (output < 2 ? 1e-4 : 1e-3) || errors[output].rms > 1e-4) numerical = false;
    }
    // Transactional stereo path must match the independently interleaved reference.
    backend.reset(0);
    backend.reset(1);
    double stereo_error = 0;
    for (int frame = 0; frame < 2; ++frame) {
        if (generation.load() != id) return "{\"state\":\"cancelled\"}";
        const auto stereo = backend.process_stereo({{inputs[0][frame], inputs[1][frame]}});
        for (int eye = 0; eye < 2; ++eye) for (int output = 0; output < 6; ++output)
            stereo_error = std::max(stereo_error, difference(stereo[eye][output], actual[eye][frame][output]).maximum);
    }
    // A bad right eye must not advance the left eye; retry is still frame zero.
    backend.reset(0);
    backend.reset(1);
    bool rejected = false;
    try { backend.process_stereo({{inputs[0][0], ncnn::Mat()}}); }
    catch (const std::exception&) { rejected = true; }
    const auto retry = backend.process_stereo({{inputs[0][0], inputs[1][0]}});
    double rollback_error = 0;
    for (int eye = 0; eye < 2; ++eye) for (int output = 0; output < 6; ++output)
        rollback_error = std::max(rollback_error, difference(retry[eye][output], actual[eye][0][output]).maximum);
    std::ostringstream json;
    json << std::setprecision(12)
         << "{\"schema_version\":2,\"state\":\"" << (numerical && isolation_error <= 1e-6 && reset_error <= 1e-6 &&
             stereo_error <= 1e-6 && rejected && rollback_error <= 1e-6 ? "passed" : "failed")
         << "\",\"profile\":\"" << profile.id << "\",\"profile_key\":\"" << profile.key
         << "\",\"backend\":\"" << (vulkan ? "ncnn_vulkan" : "ncnn_cpu")
         << "\",\"scope\":\"Synthetic full recurrence validation; not quality or thermal performance\","
         << "\"state_storage\":\"host_fp32_validation\",\"threads\":4,\"frames_per_eye\":2,"
         << "\"vulkan_capable_layers\":" << backend.vulkan_capable_layers() << ",\"layer_count\":" << backend.layer_count()
         << ",\"isolation_max_abs\":" << isolation_error << ",\"reset_max_abs\":" << reset_error
         << ",\"stereo_max_abs\":" << stereo_error << ",\"rollback_max_abs\":" << rollback_error
         << ",\"invalid_eye_rejected\":" << (rejected ? "true" : "false") << ",\"errors\":{";
    for (int output = 0; output < 6; ++output) {
        if (output) json << ',';
        json << '"' << output_names[output] << "\":{\"max_abs\":" << errors[output].maximum << ",\"rms\":" << errors[output].rms << '}';
    }
    json << "},\"validation_process_ms\":[";
    for (size_t index = 0; index < timings.size(); ++index) { if (index) json << ','; json << timings[index]; }
    json << "],\"quality_tested\":false,\"thermal_tested\":false,\"video_integrated\":false}";
    return json.str();
}
} // namespace

extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_RvmNative_setGeneration(JNIEnv*, jclass, jint id) {
    generation.store(id);
}

extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_RvmNative_runBenchmark(JNIEnv* env, jclass, jobject manager, jboolean vulkan, jint id, jstring key) {
    try {
        if (!key) throw std::runtime_error("RVM profile key missing");
        const char* chars = env->GetStringUTFChars(key, nullptr);
        if (!chars) return nullptr;
        const std::string profile_key(chars);
        env->ReleaseStringUTFChars(key, chars);
        const auto result = benchmark(AAssetManager_fromJava(env, manager), vulkan == JNI_TRUE, id, quest::find_profile(profile_key));
        return env->NewStringUTF(result.c_str());
    } catch (const std::exception& error) {
        __android_log_print(ANDROID_LOG_ERROR, "VRPassthroughPlayer", "RVM benchmark: %s", error.what());
        return env->NewStringUTF("{\"schema_version\":1,\"state\":\"error\",\"code\":\"RVM_NATIVE_BENCHMARK_FAILED\"}");
    }
}
