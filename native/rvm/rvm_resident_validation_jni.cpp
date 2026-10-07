#include "rvm_resident_validation.h"
#include <android/asset_manager_jni.h>
#include <android/log.h>
#include <jni.h>
#include <fstream>
#include <stdexcept>

static jstring run_validation(JNIEnv* env, jobject manager, jstring key, jstring directory,
                              quest::RvmPrecision precision) {
    try {
        if (!key || !directory) throw std::runtime_error("Resident fixture path missing");
        const char* profile_text = env->GetStringUTFChars(key, nullptr);
        if (!profile_text) return nullptr;
        const std::string profile_key(profile_text);
        env->ReleaseStringUTFChars(key, profile_text);
        const char* directory_text = env->GetStringUTFChars(directory, nullptr);
        if (!directory_text) return nullptr;
        const std::string root(directory_text);
        env->ReleaseStringUTFChars(directory, directory_text);
        auto* assets = AAssetManager_fromJava(env, manager);
        if (!assets) throw std::runtime_error("AssetManager missing");
        quest::RvmBackend backend(assets, true, quest::find_profile(profile_key), precision);
        const auto result = quest::validate_resident(backend, [&](const std::string& file, quest::TensorShape shape) {
            std::ifstream stream(root+"/"+file, std::ios::binary);
            if (!stream) throw std::runtime_error("Resident fixture missing: "+file);
            ncnn::Mat value(shape.width, shape.height, shape.channels);
            for (int channel = 0; channel < shape.channels; ++channel) {
                stream.read(reinterpret_cast<char*>(static_cast<float*>(value.channel(channel))), shape.width*shape.height*sizeof(float));
                if (!stream) throw std::runtime_error("Resident fixture truncated");
            }
            if (stream.peek() != std::ifstream::traits_type::eof()) throw std::runtime_error("Resident fixture trailing data");
            quest::check_tensor(value, shape);
            return value;
        });
        return env->NewStringUTF(result.c_str());
    } catch (const std::exception& failure) {
        __android_log_print(ANDROID_LOG_ERROR, "VRPassthroughPlayer", "Resident validation: %s", failure.what());
        return env->NewStringUTF("{\"state\":\"error\",\"code\":\"RESIDENT_VALIDATION_FAILED\"}");
    }
}

extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_RvmResidentValidationNative_run(JNIEnv* env, jclass,
    jobject manager, jstring key, jstring directory) {
    return run_validation(env, manager, key, directory, quest::RvmPrecision::FP32);
}

extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_RvmResidentValidationNative_runHalfStorage(JNIEnv* env, jclass,
    jobject manager, jstring key, jstring directory) {
    return run_validation(env, manager, key, directory, quest::RvmPrecision::FP16Storage);
}
