#include <jni.h>
#include <android/log.h>
#include <mpv/client.h>
#include <chrono>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>

extern "C" int av_jni_set_java_vm(void*, void*);
extern "C" int av_jni_set_android_app_ctx(void*, void*);
std::string quest_mpv_gpu_probe(const std::string& path, bool hardware, int width, int height, bool source_frame);

namespace {
std::mutex probe_mutex;
jobject application_context = nullptr; // Process lifetime, matching FFmpeg's global context.
std::string quote(const std::string& value) {
    std::string result = "\"";
    for (const unsigned char c : value) {
        if (c == '"' || c == '\\') { result += '\\'; result += static_cast<char>(c); }
        else if (c == '\n') result += "\\n";
        else if (c == '\r') result += "\\r";
        else if (c == '\t') result += "\\t";
        else if (c >= 32) result += static_cast<char>(c);
    }
    return result + '"';
}
void checked(int status, const char* action) {
    if (status < 0) throw std::runtime_error(std::string(action)+": "+mpv_error_string(status));
}
std::string property(mpv_handle* core, const char* name) {
    char* value = mpv_get_property_string(core, name);
    const std::string result = value ? value : "";
    mpv_free(value);
    return result;
}
void initialize_android(JNIEnv* env, jobject context) {
    if (!context) throw std::runtime_error("MPV diagnostic context missing");
    if (!application_context) {
        JavaVM* vm = nullptr; checked(env->GetJavaVM(&vm), "GetJavaVM");
        checked(av_jni_set_java_vm(vm, nullptr), "FFmpeg Java VM");
        application_context = env->NewGlobalRef(context);
        if (!application_context) throw std::runtime_error("MPV application context allocation failed");
        checked(av_jni_set_android_app_ctx(application_context, nullptr), "FFmpeg Android context");
    }
}
std::string probe(JNIEnv* env, jobject context, jstring path) {
    std::lock_guard<std::mutex> lock(probe_mutex);
    if (!path) throw std::runtime_error("MPV diagnostic path missing");
    initialize_android(env, context);
    std::unique_ptr<mpv_handle, decltype(&mpv_terminate_destroy)> core(mpv_create(), mpv_terminate_destroy);
    if (!core) throw std::runtime_error("mpv_create failed");
    const auto option = [&](const char* name, const char* value) { checked(mpv_set_option_string(core.get(), name, value), name); };
    option("config", "no"); option("load-scripts", "no"); option("terminal", "no");
    option("vo", "null"); option("audio", "no"); option("hwdec", "no");
    option("speed", "10"); option("keep-open", "no"); option("idle", "yes");
    option("pause", "yes"); // Snapshot the first decoded format before a short fixture reaches EOF.
    checked(mpv_request_log_messages(core.get(), "info"), "mpv log subscription");
    checked(mpv_initialize(core.get()), "mpv_initialize");
    const std::string version = property(core.get(), "mpv-version");
    const std::string ffmpeg = property(core.get(), "ffmpeg-version");
    const char* utf = env->GetStringUTFChars(path, nullptr);
    if (!utf) throw std::runtime_error("MPV path allocation failed");
    const std::string source = utf; env->ReleaseStringUTFChars(path, utf);
    const char* command[] = {"loadfile", source.c_str(), nullptr};
    checked(mpv_command(core.get(), command), "mpv loadfile");
    bool loaded = false, reconfigured = false, resumed = false, ended = false;
    int end_reason = -1, playback_error = 0;
    std::string codec, demuxer, width, height, duration;
    const auto deadline = std::chrono::steady_clock::now()+std::chrono::seconds(20);
    while (std::chrono::steady_clock::now() < deadline && !ended) {
        const auto* event = mpv_wait_event(core.get(), 0.1);
        if (!event) throw std::runtime_error("mpv_wait_event failed");
        if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
            const auto* log = static_cast<const mpv_event_log_message*>(event->data);
            __android_log_print(ANDROID_LOG_INFO, "QuestMpv", "[%s] %s", log->prefix, log->text);
        } else if (event->event_id == MPV_EVENT_FILE_LOADED) loaded = true;
        else if (event->event_id == MPV_EVENT_VIDEO_RECONFIG) {
            reconfigured = true;
            if (!resumed) {
                codec = property(core.get(), "video-codec"); demuxer = property(core.get(), "file-format");
                width = property(core.get(), "video-params/w"); height = property(core.get(), "video-params/h");
                duration = property(core.get(), "duration");
                if (!codec.empty() && !width.empty() && !height.empty()) {
                    checked(mpv_set_property_string(core.get(), "pause", "no"), "resume after format snapshot");
                    resumed = true;
                }
            }
        } else if (event->event_id == MPV_EVENT_END_FILE) {
            const auto* end = static_cast<const mpv_event_end_file*>(event->data);
            ended = true; end_reason = end->reason; playback_error = end->error;
        }
    }
    const bool passed = loaded && reconfigured && resumed && ended && end_reason == MPV_END_FILE_REASON_EOF &&
        playback_error == 0 && !codec.empty() && !width.empty() && !height.empty();
    return "{\"state\":"+quote(passed ? "passed" : "failed")+
        ",\"mpv_version\":"+quote(version)+",\"ffmpeg_version\":"+quote(ffmpeg)+
        ",\"client_api\":"+std::to_string(mpv_client_api_version())+
        ",\"file_loaded\":"+(loaded ? "true" : "false")+",\"video_reconfigured\":"+(reconfigured ? "true" : "false")+
        ",\"ended\":"+(ended ? "true" : "false")+",\"end_reason\":"+std::to_string(end_reason)+
        ",\"resumed_after_format_snapshot\":"+(resumed ? "true" : "false")+
        ",\"playback_error\":"+std::to_string(playback_error)+",\"codec\":"+quote(codec)+
        ",\"demuxer\":"+quote(demuxer)+",\"width\":"+quote(width)+",\"height\":"+quote(height)+
        ",\"duration\":"+quote(duration)+",\"hardware_decode\":false,\"audio_enabled\":false,\"vo\":\"null\","+
        "\"scope\":\"Android libmpv load/demux/software decode/EOS only; GPU/XR/RVM/audio/PTS unverified\"}";
}
extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_MpvNative_probeGpu(JNIEnv* env, jclass, jobject context,
                                                     jstring path, jboolean hardware, jint width, jint height, jboolean source_frame) {
    try {
        std::lock_guard<std::mutex> lock(probe_mutex);
        initialize_android(env, context);
        if (!path) throw std::runtime_error("MPV GPU diagnostic path missing");
        const char* utf = env->GetStringUTFChars(path, nullptr);
        if (!utf) throw std::runtime_error("MPV path allocation failed");
        const std::string source = utf;
        env->ReleaseStringUTFChars(path, utf);
        return env->NewStringUTF(quest_mpv_gpu_probe(source, hardware == JNI_TRUE, width, height, source_frame == JNI_TRUE).c_str());
    } catch (const std::exception& error) {
        const auto type = env->FindClass("java/lang/IllegalStateException");
        if (type && !env->ExceptionCheck()) env->ThrowNew(type, error.what());
        return nullptr;
    }
}
}
void quest_mpv_initialize_android(JNIEnv* env, jobject context) {
    std::lock_guard<std::mutex> lock(probe_mutex);
    initialize_android(env, context);
}
extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_MpvNative_probe(JNIEnv* env, jclass, jobject context, jstring path) {
    try { return env->NewStringUTF(probe(env, context, path).c_str()); }
    catch (const std::exception& error) {
        const auto type = env->FindClass("java/lang/IllegalStateException");
        if (type && !env->ExceptionCheck()) env->ThrowNew(type, error.what());
        return nullptr;
    }
}
