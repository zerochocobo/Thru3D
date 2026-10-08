#include <jni.h>
#include <mpv/client.h>
#include <mpv/render_gl.h>
#include <mpv/quest_frame.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <android/log.h>
#include <android/hardware_buffer.h>
#include <media/NdkImage.h>
#include <sys/system_properties.h>
#include <dlfcn.h>
#include <array>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <condition_variable>
#include <limits>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>
#include "json_quote.h"

void quest_mpv_initialize_android(JNIEnv*, jobject);

namespace {
void require(bool ok, const char* action) { if (!ok) throw std::runtime_error(action); }
void checked(int result, const char* action) {
    if (result < 0) throw std::runtime_error(std::string(action) + ": " + mpv_error_string(result));
}
std::string quote(const std::string& value) {
    return quest::json_quote(value);
}
std::string property(mpv_handle* core, const char* key) {
    char* text = mpv_get_property_string(core, key);
    std::string value = text ? text : ""; mpv_free(text); return value;
}
std::string seconds_property(mpv_handle* core, const char* key) {
    double value = 0;
    if (mpv_get_property(core, key, MPV_FORMAT_DOUBLE, &value) < 0 || !std::isfinite(value)) return "";
    return std::to_string(value);
}
std::string audio_position(mpv_handle* core) {
    double value = 0;
    if (mpv_get_property(core, "audio-pts", MPV_FORMAT_DOUBLE, &value) < 0 ||
        !std::isfinite(value) || std::abs(value) > static_cast<double>(std::numeric_limits<int64_t>::max()/1000000)) return "null";
    // Negative startup values are allowed by MPV's AO-delay-aware property.
    return std::to_string(static_cast<int64_t>(std::llround(value*1000000)));
}
const mpv_node* member(const mpv_node& node, const char* key) {
    if (node.format != MPV_FORMAT_NODE_MAP) return nullptr;
    for (int i = 0; i < node.u.list->num; ++i)
        if (std::string(node.u.list->keys[i]) == key) return &node.u.list->values[i];
    return nullptr;
}
std::string node_text(const mpv_node& node, const char* key) {
    const auto* value = member(node, key);
    return value && value->format == MPV_FORMAT_STRING ? value->u.string : "";
}
struct OwnedNode { mpv_node value{}; ~OwnedNode() { mpv_free_node_contents(&value); } };
struct ActiveFlag {
    std::atomic<bool>& flag;
    explicit ActiveFlag(std::atomic<bool>& value) : flag(value) { flag.store(true); }
    ~ActiveFlag() { flag.store(false); }
};
bool extension_available() {
    auto version = reinterpret_cast<uint32_t (*)()>(dlsym(RTLD_DEFAULT, "mpv_quest_source_frame_api_version"));
    return version && version() == QUEST_MPV_SOURCE_FRAME_API_VERSION;
}
enum class Phase { free, rendering, ready, acquired, retiring };
struct Slot {
    GLuint color = 0, fbo = 0;
    GLsync fence = nullptr;
    Phase phase = Phase::free;
    uint64_t token = 0;
    bool allow_repeat = false;
    int out_width = 0, out_height = 0; // color size; smaller than the source when output is capped
    quest_mpv_source_frame ticket{};
    // Direct mode: the decoder's own image (exported by MPV, owned here) instead of an RGBA copy;
    // `color` is then only MPV's tiny render target. Deleted when the slot is dropped or retired.
    AImage* image = nullptr;
    AHardwareBuffer* buffer = nullptr;
    int buffer_width = 0, buffer_height = 0;
};
void drop_image(Slot& slot) {
    if (slot.image) AImage_delete(slot.image);
    slot.image = nullptr; slot.buffer = nullptr; slot.buffer_width = slot.buffer_height = 0;
}

// MPV ordinary APIs belong exclusively to control_thread. Render APIs and all
// producer GL operations belong exclusively to render_thread. Neither a callback
// nor the render thread waits for a control-thread operation to return.
struct Source final {
    const EGLDisplay display = eglGetCurrentDisplay();
    const EGLContext owner_context = eglGetCurrentContext();
    const std::thread::id owner_thread = std::this_thread::get_id();
    const std::string path;
    const bool hardware, audio, exact_start;
    const int start_ms;
    const std::chrono::steady_clock::time_point created_at = std::chrono::steady_clock::now();
    std::atomic<int64_t> initialized_us{-1}, renderer_ready_us{-1}, load_submitted_us{-1}, file_loaded_us{-1}, first_published_us{-1};
    int64_t startup_us() const {
        return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - created_at).count();
    }
    // Extra audio tracks beside the video (location, title), e.g. a clone-voice M4A. Added unselected
    // once the file loads; a track that fails to open is logged and skipped.
    const std::vector<std::pair<std::string, std::string>> audio_files;
    const std::vector<std::pair<std::string, std::string>> subtitle_files;
    std::atomic<bool> closing{false}, abandoned{false}, done{false}, render_ready{false};
    std::atomic<bool> render_failed{false}, render_pending{true}, force_redraw{false};
    std::atomic<bool> core_eof{false};
    std::atomic<bool> seek_in_progress{false}, render_in_progress{false};
    std::atomic<uint64_t> stale_seek_frames_discarded{0};
    std::atomic<uint64_t> dimensions{0}, last_epoch{0}, epoch_floor{0};
    std::atomic<uint64_t> rendered{0}, skipped{0}, published{0}, acquired{0}, released{0};
    std::atomic<uint64_t> seeks_started{0}, seeks_completed{0}, invalid_frames{0};
    std::atomic<uint64_t> audio_commands_applied{0};
    // RVM sessions cap presented source frames (0 = every frame). Decimation uses
    // each frame's scheduled display time, before its full-size render.
    std::atomic<int> max_fps{0};
    std::atomic<bool> cadence_reset{true};
    std::atomic<uint64_t> cadence_skipped{0}, cadence_untimed{0};
    // Output width cap (0 = source size). MPV scales into the smaller color in its single pass,
    // cutting the per-frame RGBA write, the bridge copy and Godot's sampling bandwidth.
    std::atomic<int> max_output_width{0};
    // Direct mode (Alpha): publish MPV's exported MediaCodec images; no full-resolution RGBA render.
    std::atomic<bool> direct{false};
    std::atomic<bool> cadence_target_ns{false};
    uint64_t subtitle_requests = 0, desired_subtitle_command = 0; // commands_mutex
    uint64_t subtitle_command_applied = 0, subtitle_sequence = 0; // control thread
    std::vector<int64_t> subtitle_track_ids; // commands_mutex
    int desired_subtitle_id = 0;
    bool subtitle_dirty = false;
    std::string subtitle_snapshot; // status_mutex
    uint64_t published_subtitle_sequence = 0; // status_mutex
    int64_t published_subtitle_ns = 0; // status_mutex
    std::mutex frames_mutex, commands_mutex, status_mutex, wait_mutex;
    std::condition_variable wake;
    // The render bridge may hold all five of its slots as borrowed Alpha colors while MPV renders
    // ahead; slots allocate lazily, so playback that copies uses about three.
    std::array<Slot, 7> slots;
    uint64_t token_sequence = 0, last_acquired_token = 0; // guarded by frames_mutex
    uint64_t last_acquired_id = 0, last_acquired_epoch = 0;
    quest_mpv_source_frame final_ticket{}; // frames_mutex; resolved by a retained render after core EOF
    bool awaiting_seek_event = false; // control thread only
    bool desired_play = false, playing_dirty = false;
#ifndef NDEBUG
    // One outstanding forward step, only for the bounded offline motion probe.
    bool debug_step_pending = false; // commands_mutex
    std::atomic<bool> debug_step_active{false};
    std::atomic<uint64_t> debug_steps_applied{0}, debug_step_images{0};
#endif
    int64_t pending_seek_ms = -1;
    bool pending_seek_exact = true; // commands_mutex; coalesced with the target
    std::atomic<bool> last_seek_exact{true};
    std::vector<int64_t> audio_track_ids; // commands_mutex; from actual MPV track-list
    int desired_audio_id = -1; double desired_volume = 100; bool desired_mute = false, audio_dirty = false;
    uint64_t snapshot_sequence = 0; // control thread only
    std::string state = "opening", details = "{}", error, render_error;
    std::thread control_thread, render_thread;

    Source(std::string file, bool hw, bool with_audio, int position,
           std::vector<std::pair<std::string, std::string>> extra_audio = {},
           std::vector<std::pair<std::string, std::string>> extra_subtitles = {}, bool precise_start = true)
        : path(std::move(file)), hardware(hw), audio(with_audio), exact_start(precise_start), start_ms(position),
          audio_files(std::move(extra_audio)), subtitle_files(std::move(extra_subtitles)), last_seek_exact(precise_start) {
        require(display != EGL_NO_DISPLAY && owner_context != EGL_NO_CONTEXT,
                "MPV source must start in the Godot GLES owner context");
    }
    void start() { control_thread = std::thread([this] { control(); }); }
    ~Source() {
        closing.store(true); abandoned.store(true); wake.notify_all();
        if (control_thread.joinable()) control_thread.join();
    }
    void owner() const {
        require(eglGetCurrentDisplay() == display && eglGetCurrentContext() == owner_context &&
                std::this_thread::get_id() == owner_thread, "MPV lease requires its Godot owner thread/context");
    }
    static void callback(void* opaque) noexcept {
        auto* source = static_cast<Source*>(opaque);
        source->render_pending.store(true); source->wake.notify_one();
    }
    static void* resolve(void* library, const char* name) {
        void* symbol = reinterpret_cast<void*>(eglGetProcAddress(name));
        return symbol ? symbol : dlsym(library, name);
    }
    void set_state(std::string value, std::string failure = "") {
        std::lock_guard<std::mutex> lock(status_mutex);
        state = std::move(value); if (!failure.empty()) error = std::move(failure);
    }
    void snapshot(mpv_handle* core) {
        // All property reads happen before taking the status lock.
        const auto codec = property(core, "video-codec"), hwdec = property(core, "hwdec-current");
        const auto position = property(core, "time-pos"), duration = property(core, "duration");
        const auto seekable = property(core, "seekable"), partial = property(core, "partially-seekable");
        const auto file_size = property(core, "file-size");
        const auto matrix = property(core, "video-params/colormatrix"), range = property(core, "video-params/colorlevels");
        const auto transfer = property(core, "video-params/gamma"), paused = property(core, "pause");
        const auto audio_codec = property(core, "audio-codec"), ao = property(core, "current-ao");
        const auto audio_pts = audio_position(core), aid = property(core, "current-tracks/audio/id");
        const auto volume = property(core, "volume"), mute = property(core, "mute");
        const auto rate = property(core, "audio-params/samplerate"), channels = property(core, "audio-params/channel-count");
        const auto avsync = property(core, "avsync"), cache_pause = property(core, "paused-for-cache");
        const auto decoder_drops = property(core, "decoder-frame-drop-count");
        std::string tracks_json = "["; std::vector<int64_t> track_ids;
        std::string subtitles_json = "["; std::vector<int64_t> subtitle_ids;
        OwnedNode tracks;
        if (mpv_get_property(core, "track-list", MPV_FORMAT_NODE, &tracks.value) >= 0 && tracks.value.format == MPV_FORMAT_NODE_ARRAY) {
            for (int i = 0; i < tracks.value.u.list->num; ++i) {
                const auto& track = tracks.value.u.list->values[i]; const auto* id = member(track, "id");
                const auto type = node_text(track, "type");
                if ((type != "audio" && type != "sub") || !id || id->format != MPV_FORMAT_INT64 || id->u.int64 <= 0) continue;
                auto& ids = type == "audio" ? track_ids : subtitle_ids;
                auto& list = type == "audio" ? tracks_json : subtitles_json;
                if (!ids.empty()) list += ',';
                ids.push_back(id->u.int64);
                const auto* external = member(track, "external");
                list += "{\"id\":" + std::to_string(id->u.int64) + ",\"title\":" + quote(node_text(track, "title")) +
                    ",\"language\":" + quote(node_text(track, "lang")) + ",\"codec\":" + quote(node_text(track, "codec")) +
                    ",\"external\":" + (external && external->format == MPV_FORMAT_FLAG && external->u.flag ? "true" : "false") + "}";
            }
        }
        tracks_json += ']';
        subtitles_json += ']';
        { std::lock_guard<std::mutex> lock(commands_mutex); audio_track_ids = std::move(track_ids); subtitle_track_ids = std::move(subtitle_ids); }
        const auto subtitle_id = property(core, "current-tracks/sub/id");
        const bool subtitle_timeline_valid = !awaiting_seek_event && !seek_in_progress.load() && last_epoch.load() >= epoch_floor.load();
        const auto subtitle_text = subtitle_timeline_valid ? property(core, "sub-text") : "";
        const auto subtitle_start = seconds_property(core, "sub-start"), subtitle_end = seconds_property(core, "sub-end");
        const auto observed_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
        const auto eof = property(core, "eof-reached");
        const auto subtitle_json = "{\"sequence\":" + std::to_string(++subtitle_sequence) +
            ",\"command_id\":" + std::to_string(subtitle_command_applied) + ",\"track_id\":" + quote(subtitle_id) +
            ",\"text\":" + quote(subtitle_text) + ",\"start_seconds\":" + quote(subtitle_start) +
            ",\"end_seconds\":" + quote(subtitle_end) + ",\"position_seconds\":" + quote(seconds_property(core, "time-pos")) +
            ",\"source_epoch\":" + std::to_string(last_epoch.load()) +
            ",\"timeline_valid\":" + (subtitle_timeline_valid ? "true" : "false") +
            ",\"observed_monotonic_ns\":" + std::to_string(observed_ns) +
            ",\"clock_scope\":\"MPV_playback_observation_not_same_video_frame_ticket\",\"rendered_into_video\":false}";
        core_eof.store(eof == "yes" && !awaiting_seek_event && last_epoch.load() >= epoch_floor.load());
        const auto json = "{\"codec\":" + quote(codec) + ",\"hwdec_current\":" + quote(hwdec) +
            ",\"position_seconds\":" + quote(position) + ",\"duration_seconds\":" + quote(duration) +
            ",\"seekable\":" + quote(seekable) + ",\"partially_seekable\":" + quote(partial) + ",\"file_size\":" + quote(file_size) +
            ",\"paused\":" + quote(paused) + ",\"color_matrix\":" + quote(matrix) +
            ",\"color_range\":" + quote(range) + ",\"color_transfer\":" + quote(transfer) +
            ",\"audio_codec\":" + quote(audio_codec) + ",\"audio_output\":" + quote(ao) +
            ",\"audio_pts_us\":" + audio_pts + ",\"audio_clock_available\":" + (audio_pts == "null" ? "false" : "true") +
            ",\"audio_track_id\":" + quote(aid) + ",\"audio_tracks\":" + tracks_json +
            ",\"subtitle_tracks\":" + subtitles_json + ",\"subtitle\":" + subtitle_json +
            ",\"volume\":" + quote(volume) + ",\"mute\":" + quote(mute) + ",\"audio_samplerate\":" + quote(rate) +
            ",\"audio_channels\":" + quote(channels) + ",\"avsync_seconds\":" + quote(avsync) +
            ",\"paused_for_cache\":" + quote(cache_pause) + ",\"decoder_frame_drop_count\":" + quote(decoder_drops) +
            ",\"snapshot_sequence\":" + std::to_string(++snapshot_sequence) +
            ",\"observed_monotonic_ns\":" + std::to_string(observed_ns) +
            ",\"clock_observation_scope\":\"MPV_audio_pts_including_AO_delay;_not_same_render_source_ticket_or_Godot_presentation\",\"eof_reached\":" + quote(eof) + "}";
        std::lock_guard<std::mutex> lock(status_mutex); details = json; subtitle_snapshot = subtitle_json;
        published_subtitle_sequence = subtitle_sequence;
        published_subtitle_ns = observed_ns;
        if (!codec.empty() && state != "failed") state = eof == "yes" ? "ended" : (paused == "yes" ? "paused" : "playing");
    }
    bool format(mpv_handle* core) {
        int64_t width = 0, height = 0;
        const int w = mpv_get_property(core, "video-out-params/w", MPV_FORMAT_INT64, &width);
        const int h = mpv_get_property(core, "video-out-params/h", MPV_FORMAT_INT64, &height);
        // VIDEO_RECONFIG can announce a temporarily empty output while the
        // hardware decoder/filter chain starts. Retry on the control thread.
        if (w == MPV_ERROR_PROPERTY_UNAVAILABLE || h == MPV_ERROR_PROPERTY_UNAVAILABLE) return false;
        checked(w, "MPV output width"); checked(h, "MPV output height");
        require(width > 0 && height > 0 && width <= 8192 && height <= 8192 && width*height <= 8192LL*4320,
                "MPV source dimensions exceed the current GPU slot contract");
        const uint64_t size = (static_cast<uint64_t>(width) << 32) | static_cast<uint32_t>(height);
        const auto previous = dimensions.load();
        require(previous == 0 || previous == size, "MPV midstream size change requires a new format generation");
        dimensions.store(size); wake.notify_one();
        return true;
    }
    void control() noexcept {
        mpv_handle* core = nullptr;
        try {
            core = mpv_create(); require(core != nullptr, "MPV source create failed");
            auto option = [&](const char* key, const char* value) { checked(mpv_set_option_string(core, key, value), key); };
            option("config", "no"); option("load-scripts", "no"); option("terminal", "no");
            option("vo", "libmpv"); option("hwdec", hardware ? "mediacodec" : "no"); option("hwdec-codecs", "all");
            option("audio", audio ? "auto" : "no"); option("pause", "yes"); option("idle", "yes"); option("keep-open", "yes");
            // Initial/continued playback must use the same policy as subsequent seeks.
            // Explicit seek flags below still allow an independent bookmark override.
            option("hr-seek", exact_start ? "yes" : "no");
            if (audio) { option("ao", "aaudio"); option("aaudio-performance-mode", "low-latency"); }
            // Network sources: a deep read-ahead absorbs Wi-Fi jitter for 8K bitrates.
            option("cache", "auto"); option("demuxer-max-bytes", "256MiB"); option("demuxer-readahead-secs", "20");
            option("network-timeout", "30");
            option("osd-level", "0"); option("sub", "no"); option("sub-visibility", "no"); option("interpolation", "no"); option("dither", "no");
            option("scale", "bilinear"); option("cscale", "bilinear"); option("dscale", "bilinear");
            // One direct OES -> RGBA8 pass instead of an 8K RGBA16F intermediate plus a
            // second 8K pass: -65% video-path bandwidth on Quest 3 (ovrgpuprofiler).
            // Cost: no chroma-location/linear-light processing; R09 RGB mean 0.21/255,
            // p99 5/255, max 40/255 at high-contrast edges.
            option("gpu-dumb-mode", "yes");
#ifndef NDEBUG
            {
                char value[PROP_VALUE_MAX] = {};
                if (__system_property_get("debug.vrpp.mpv.max_width", value) > 0) max_output_width.store(std::max(0, atoi(value)));
            }
            // Debug-only A/B of render options for GPU profiling, e.g.
            // adb shell setprop debug.vrpp.mpv.opts gpu-dumb-mode=yes,fbo-format=rgba8
            char overrides[PROP_VALUE_MAX] = {};
            if (__system_property_get("debug.vrpp.mpv.opts", overrides) > 0) {
                std::string list = overrides;
                size_t start = 0;
                while (start < list.size()) {
                    const auto end = std::min(list.find(',', start), list.size());
                    const auto item = list.substr(start, end - start);
                    const auto eq = item.find('=');
                    if (eq != std::string::npos) {
                        option(item.substr(0, eq).c_str(), item.substr(eq + 1).c_str());
                        __android_log_print(ANDROID_LOG_WARN, "QuestMpv", "debug option %s", item.c_str());
                    }
                    start = end + 1;
                }
            }
#endif
            checked(mpv_request_log_messages(core, "debug"), "MPV source log subscription");
            checked(mpv_initialize(core), "MPV source initialize");
            initialized_us.store(startup_us());
            checked(mpv_observe_property(core, 41, "sub-text", MPV_FORMAT_STRING), "MPV subtitle text observation");
            render_thread = std::thread([this, core] { render(core); });
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
            while (!render_ready.load() && !render_failed.load() && !closing.load() && std::chrono::steady_clock::now() < deadline)
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            require(render_ready.load() && !render_failed.load(), "MPV shared renderer failed to initialize");
            renderer_ready_us.store(startup_us());
            if (!closing.load()) {
                const std::string start = "start=" + std::to_string(start_ms / 1000.0);
                const char* load[] = {"loadfile", path.c_str(), "replace", "-1", start.c_str(), nullptr};
                checked(mpv_command(core, load), "MPV source loadfile");
                load_submitted_us.store(startup_us());
            }
            bool loaded = false;
            auto format_deadline = std::chrono::steady_clock::time_point::max();
            auto next_snapshot = std::chrono::steady_clock::now();
            while (!closing.load() && !render_failed.load()) {
                bool set_play = false, play = false, set_audio = false, muted = false, set_subtitle = false, seek_exact = true;
#ifndef NDEBUG
                bool set_step = false;
#endif
                int subtitle_id = 0; uint64_t subtitle_command = 0;
                int audio_id = -1; double volume = 100; int64_t seek = -1;
                {
                    std::lock_guard<std::mutex> lock(commands_mutex);
                    if (loaded) {
                        set_play = playing_dirty; play = desired_play; playing_dirty = false;
#ifndef NDEBUG
                        set_step = debug_step_pending; debug_step_pending = false;
#endif
                        seek = pending_seek_ms; seek_exact = pending_seek_exact; pending_seek_ms = -1;
                        set_audio = audio_dirty; audio_dirty = false;
                        audio_id = desired_audio_id; volume = desired_volume; muted = desired_mute;
                        set_subtitle = subtitle_dirty; subtitle_dirty = false;
                        subtitle_id = desired_subtitle_id; subtitle_command = desired_subtitle_command;
                    }
                }
                if (set_play && !play) checked(mpv_set_property_string(core, "pause", "yes"), "MPV source pause before audio");
                if (set_audio) {
                    const auto selected = audio_id < 0 ? "auto" : (audio_id == 0 ? "no" : std::to_string(audio_id));
                    checked(mpv_set_property_string(core, "aid", selected.c_str()), "MPV audio track");
                    checked(mpv_set_property(core, "volume", MPV_FORMAT_DOUBLE, &volume), "MPV volume");
                    int mute = muted ? 1 : 0;
                    checked(mpv_set_property(core, "mute", MPV_FORMAT_FLAG, &mute), "MPV mute");
                    audio_commands_applied.fetch_add(1);
                }
                if (set_subtitle) {
                    const auto selected = subtitle_id < 0 ? "auto" : (subtitle_id == 0 ? "no" : std::to_string(subtitle_id));
                    checked(mpv_set_property_string(core, "sid", selected.c_str()), "MPV subtitle track");
                    subtitle_command_applied = subtitle_command;
                    next_snapshot = std::chrono::steady_clock::now();
                }
                if (seek >= 0) {
                    // Flush cannot invalidate a MediaCodec surface while the
                    // worker is mapping that surface. The worker still serves
                    // advanced-control update tasks while new renders wait.
                    ActiveFlag seeking(seek_in_progress);
                    const auto idle_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
                    while (render_in_progress.load() && !closing.load() && !render_failed.load() &&
                           std::chrono::steady_clock::now() < idle_deadline)
                        std::this_thread::sleep_for(std::chrono::milliseconds(1));
                    if (closing.load()) break;
                    require(!render_in_progress.load() && !render_failed.load(), "MPV seek renderer did not quiesce");
                    awaiting_seek_event = true; core_eof.store(false);
                    __android_log_print(ANDROID_LOG_INFO, "QuestMpvSource", "Seek request %lld ms; epoch=%llu floor=%llu mode=%s",
                        static_cast<long long>(seek), static_cast<unsigned long long>(last_epoch.load()),
                        static_cast<unsigned long long>(epoch_floor.load()), seek_exact ? "exact" : "speed");
                    seeks_started.fetch_add(1);
                    last_seek_exact.store(seek_exact);
                    const auto seconds = std::to_string(seek / 1000.0);
                    const char* command[] = {"seek", seconds.c_str(), seek_exact ? "absolute+exact" : "absolute+keyframes", nullptr};
                    checked(mpv_command(core, command), "MPV source seek");
                    seeks_completed.fetch_add(1);
                }
                if (set_play && play) checked(mpv_set_property_string(core, "pause", "no"), "MPV source play");
#ifndef NDEBUG
                if (set_step) {
                    int paused = 0;
                    checked(mpv_get_property(core, "pause", MPV_FORMAT_FLAG, &paused), "MPV step pause observation");
                    require(paused && !set_play && seek < 0, "Debug frame step requires a paused source without seek/play");
                    // 'play' mode advances the decoder without a seek/VO reset.
                    const char* command[] = {"frame-step", "1", "play", nullptr};
                    checked(mpv_command(core, command), "MPV forward frame step");
                    debug_steps_applied.fetch_add(1);
                }
#endif
                const auto* event = mpv_wait_event(core, 0.01);
                require(event != nullptr, "MPV source event unavailable");
                if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
                    const auto* log = static_cast<const mpv_event_log_message*>(event->data);
                    __android_log_print(ANDROID_LOG_INFO, "QuestMpvSource", "[%s] %s", log->prefix, log->text);
                } else if (event->event_id == MPV_EVENT_PROPERTY_CHANGE && event->reply_userdata == 41) {
                    next_snapshot = std::chrono::steady_clock::now();
                } else if (event->event_id == MPV_EVENT_FILE_LOADED) {
                    if (!loaded && audio) for (const auto& [location, title] : audio_files) {
                        // "auto": listed for the user, never selected over the video's own audio.
                        const char* add[] = {"audio-add", location.c_str(), "auto", title.c_str(), nullptr};
                        const int added = mpv_command(core, add);
                        __android_log_print(added < 0 ? ANDROID_LOG_WARN : ANDROID_LOG_INFO, "QuestMpvSource",
                            "Extra audio track '%s': %s", title.c_str(), mpv_error_string(added));
                    }
                    if (!loaded) for (const auto& [location, title] : subtitle_files) {
                        // Preserve the CC off/selected state, including a command sent while loading.
                        // Godot renders sub-text in its own Label3D; never burn it into the video.
                        const char* add[] = {"sub-add", location.c_str(), "auto", title.c_str(), nullptr};
                        const int added = mpv_command(core, add);
                        __android_log_print(added < 0 ? ANDROID_LOG_WARN : ANDROID_LOG_INFO, "QuestMpvSource",
                            "Extra subtitle track '%s': %s", title.c_str(), mpv_error_string(added));
                    }
                    file_loaded_us.store(startup_us());
                    loaded = true; set_state("ready");
                    format_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
                }
                else if (event->event_id == MPV_EVENT_VIDEO_RECONFIG) format(core);
                else if (event->event_id == MPV_EVENT_SEEK) { awaiting_seek_event = false; core_eof.store(false); }
                else if (event->event_id == MPV_EVENT_END_FILE) {
                    const auto* end = static_cast<const mpv_event_end_file*>(event->data);
                    if (end->error < 0) throw std::runtime_error(std::string("MPV playback: ") + mpv_error_string(end->error));
                    set_state(end->reason == MPV_END_FILE_REASON_EOF ? "ended" : "stopped");
                    // Preserve EOF slots and the last source frame until consumer retirement.
                }
                if (std::chrono::steady_clock::now() >= next_snapshot) {
                    if (loaded && dimensions.load() == 0) {
                        format(core);
                        require(dimensions.load() != 0 || std::chrono::steady_clock::now() < format_deadline,
                                "MPV video output format did not become ready within 15 seconds");
                    }
                    snapshot(core); next_snapshot = std::chrono::steady_clock::now() + std::chrono::milliseconds(100);
                }
            }
            if (render_failed.load()) set_state("failed", "Shared renderer failed; see render_error");
        } catch (const std::exception& failure) { set_state("failed", failure.what()); }
        closing.store(true); wake.notify_all();
        // Rendering disposes its context before this ordinary API destroys the core.
        if (render_thread.joinable()) render_thread.join();
        if (core) mpv_terminate_destroy(core);
        done.store(true);
    }
    void allocate(Slot& slot, int width, int height) {
        GLint maximum = 0; glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maximum);
        require(width <= maximum && height <= maximum, "MPV source exceeds device GL texture limit");
        glGenTextures(1, &slot.color); glBindTexture(GL_TEXTURE_2D, slot.color);
        glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, width, height);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glGenFramebuffers(1, &slot.fbo); glBindFramebuffer(GL_FRAMEBUFFER, slot.fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, slot.color, 0);
        require(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE && glGetError() == GL_NO_ERROR,
                "MPV shared RGBA8 slot allocation failed");
    }
    void poll_retirements() {
        for (auto& slot : slots) if (slot.phase == Phase::retiring) {
            const auto result = glClientWaitSync(slot.fence, 0, 0);
            require(result != GL_WAIT_FAILED, "MPV consumer retirement fence failed");
            if (result == GL_ALREADY_SIGNALED || result == GL_CONDITION_SATISFIED) {
                glDeleteSync(slot.fence); slot.fence = nullptr; slot.phase = Phase::free;
                drop_image(slot); // the consumer's last GPU read of the decoder image completed
            }
        }
    }
    bool consumer_holds() {
        for (auto& slot : slots) if (slot.phase == Phase::acquired || slot.phase == Phase::retiring) return true;
        return false;
    }
    void render(mpv_handle* core) noexcept {
        EGLContext context = EGL_NO_CONTEXT; EGLSurface surface = EGL_NO_SURFACE;
        mpv_render_context* renderer = nullptr; void* library = nullptr;
        try {
            require(extension_available(), "MPV private source-frame handshake unavailable");
            require(eglBindAPI(EGL_OPENGL_ES_API), "MPV shared EGL GLES binding failed");
            const EGLint attributes[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
            EGLConfig config = nullptr; EGLint count = 0;
            require(eglChooseConfig(display, attributes, &config, 1, &count) && count == 1, "MPV shared EGL config unavailable");
            const EGLint version[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
            context = eglCreateContext(display, config, owner_context, version);
            require(context != EGL_NO_CONTEXT, "MPV context sharing with Godot failed");
            const EGLint size[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
            surface = eglCreatePbufferSurface(display, config, size);
            require(surface != EGL_NO_SURFACE && eglMakeCurrent(display, surface, surface, context), "MPV shared worker context unavailable");
            library = dlopen("libGLESv3.so", RTLD_NOW | RTLD_LOCAL); require(library != nullptr, "MPV GLES symbols unavailable");
            mpv_opengl_init_params init{resolve, library}; int advanced = 1;
            mpv_render_param params[] = {{MPV_RENDER_PARAM_API_TYPE, const_cast<char*>(MPV_RENDER_API_TYPE_OPENGL)},
                {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &init}, {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced}, {MPV_RENDER_PARAM_INVALID, nullptr}};
            checked(mpv_render_context_create(&renderer, core, params), "MPV shared render context create");
            mpv_render_context_set_update_callback(renderer, callback, this); render_ready.store(true);
            bool needs_frame = false;
            int64_t last_kept_target_us = 0; // render thread only
            uint64_t cadence_floor = 0;
            while (true) {
                bool resolve_final = false;
                {
                    std::lock_guard<std::mutex> lock(frames_mutex); poll_retirements();
                    if (!core_eof.load() || final_ticket.source_epoch < epoch_floor.load()) final_ticket = {};
                    resolve_final = core_eof.load() && final_ticket.frame_id == 0;
                    if (closing.load() && (abandoned.load() || !consumer_holds())) break;
                }
                if (render_pending.exchange(false)) needs_frame |= (mpv_render_context_update(renderer) & MPV_RENDER_UPDATE_FRAME) != 0;
                const bool forced = force_redraw.exchange(false);
                needs_frame |= forced;
                bool final_render = false;
                if (resolve_final && !needs_frame) {
                    mpv_render_frame_info info{};
                    checked(mpv_render_context_get_info(renderer, {MPV_RENDER_PARAM_NEXT_FRAME_INFO, &info}), "MPV EOF render queue");
                    // A core EOF does not identify the last FBO. Drain queued
                    // frames first, then resolve the retained current image in
                    // the same private render transaction used for normal frames.
                    final_render = !(info.flags & MPV_RENDER_FRAME_INFO_PRESENT);
                    needs_frame = true;
                }
                const auto packed = dimensions.load();
                if (!needs_frame || !packed) {
                    std::unique_lock<std::mutex> lock(wait_mutex);
                    wake.wait_for(lock, std::chrono::milliseconds(2)); continue;
                }
                if (seek_in_progress.load()) {
                    std::unique_lock<std::mutex> lock(wait_mutex);
                    wake.wait_for(lock, std::chrono::milliseconds(2)); continue;
                }
                const int cap = max_fps.load();
                if (cadence_reset.exchange(false) || cadence_floor != epoch_floor.load()) {
                    last_kept_target_us = 0; cadence_floor = epoch_floor.load();
                }
                bool stepping = false;
#ifndef NDEBUG
                stepping = debug_step_active.load();
#endif
                if (cap > 0 && !forced && !final_render && !stepping) {
                    mpv_render_frame_info info{};
                    checked(mpv_render_context_get_info(renderer, {MPV_RENDER_PARAM_NEXT_FRAME_INFO, &info}), "MPV cadence frame info");
                    const bool timed = (info.flags & MPV_RENDER_FRAME_INFO_PRESENT) && !(info.flags & MPV_RENDER_FRAME_INFO_REDRAW) &&
                        info.target_time > 0;
                    if (!timed) cadence_untimed.fetch_add(1);
                    if (timed) {
                        // The pinned libmpv reports target_time in nanoseconds although
                        // render.h documents mpv_get_time_us units; detect against the clock.
                        const bool ns = info.target_time > mpv_get_time_us(core) * 100;
                        cadence_target_ns.store(ns);
                        if (ns) info.target_time /= 1000;
                        // Half a 60fps interval of tolerance keeps 59.94 -> 29.97 on
                        // alternate frames; slower sources keep every frame.
                        const int64_t period_us = 1000000 / cap, tolerance_us = 8000;
                        if (last_kept_target_us > 0 && info.target_time > last_kept_target_us &&
                            info.target_time - last_kept_target_us < period_us - tolerance_us) {
                            needs_frame = false;
                            int skip = 1;
                            mpv_render_param dropped[] = {{MPV_RENDER_PARAM_SKIP_RENDERING, &skip}, {MPV_RENDER_PARAM_INVALID, nullptr}};
                            checked(mpv_render_context_render(renderer, dropped), "MPV cadence skip");
                            mpv_render_context_report_swap(renderer); cadence_skipped.fetch_add(1); continue;
                        }
                        last_kept_target_us = info.target_time;
                    }
                }
                ActiveFlag rendering(render_in_progress);
                // Close the race between the first check and announcing the
                // transaction. Ordinary client APIs never run under this flag.
                if (seek_in_progress.load()) continue;
                const int width = static_cast<int>(packed >> 32), height = static_cast<int>(packed & 0xffffffffu);
                int out_width = width, out_height = height;
                const int width_cap = max_output_width.load();
                if (width_cap > 0 && width > width_cap) {
                    out_width = width_cap & ~1;
                    out_height = std::max(2, static_cast<int>(std::lround(static_cast<double>(height) * out_width / width)) & ~1);
                }
                Slot* target = nullptr;
                {
                    std::lock_guard<std::mutex> lock(frames_mutex);
                    if (!closing.load()) {
                        // Only unclaimed ready images can be replaced. Acquired colors
                        // cannot be touched until the consumer-context fence completes.
                        for (auto& slot : slots) if (slot.phase == Phase::free) { target = &slot; break; }
                        if (!target) for (auto& slot : slots) if (slot.phase == Phase::ready && (!target || slot.token < target->token)) target = &slot;
                        if (target) {
                            if (target->fence) {
                                // An unclaimed direct image is only read by MPV's own render: let it finish.
                                if (target->image) glClientWaitSync(target->fence, GL_SYNC_FLUSH_COMMANDS_BIT, 50000000);
                                glDeleteSync(target->fence); target->fence = nullptr;
                            }
                            drop_image(*target);
                            target->phase = Phase::rendering;
                        }
                    }
                }
                needs_frame = false;
                if (!target) {
                    if (final_render) {
                        std::unique_lock<std::mutex> lock(wait_mutex);
                        wake.wait_for(lock, std::chrono::milliseconds(2)); continue;
                    }
                    int skip = 1;
                    mpv_render_param dropped[] = {{MPV_RENDER_PARAM_SKIP_RENDERING, &skip}, {MPV_RENDER_PARAM_INVALID, nullptr}};
                    checked(mpv_render_context_render(renderer, dropped), "MPV bounded slot skip");
                    mpv_render_context_report_swap(renderer); skipped.fetch_add(1); continue;
                }
                const bool direct_render = direct.load();
                if (direct_render) { out_width = 16; out_height = 8; } // MPV still selects and times the frame
                if (target->color && (target->out_width != out_width || target->out_height != out_height)) {
                    glDeleteFramebuffers(1, &target->fbo); glDeleteTextures(1, &target->color); target->fbo = target->color = 0;
                }
                if (!target->color) { allocate(*target, out_width, out_height); target->out_width = out_width; target->out_height = out_height; }
                quest_mpv_source_frame ticket{}; ticket.struct_size = sizeof(ticket); ticket.api_version = QUEST_MPV_SOURCE_FRAME_API_VERSION;
                mpv_opengl_fbo fbo{static_cast<int>(target->fbo), out_width, out_height, GL_RGBA8}; int flip = 0;
                quest_mpv_export exported{}; exported.struct_size = sizeof(exported);
                mpv_render_param frame[] = {{MPV_RENDER_PARAM_OPENGL_FBO, &fbo}, {MPV_RENDER_PARAM_FLIP_Y, &flip},
                    {MPV_RENDER_PARAM_QUEST_SOURCE_FRAME, &ticket},
                    {direct_render ? MPV_RENDER_PARAM_QUEST_EXPORT : MPV_RENDER_PARAM_INVALID, &exported},
                    {MPV_RENDER_PARAM_INVALID, nullptr}};
                const int render_result = mpv_render_context_render(renderer, frame);
                mpv_render_context_report_swap(renderer);
                if (exported.exported && exported.image && exported.hardware_buffer) {
                    std::lock_guard<std::mutex> lock(frames_mutex);
                    target->image = reinterpret_cast<AImage*>(static_cast<uintptr_t>(exported.image));
                    target->buffer = reinterpret_cast<AHardwareBuffer*>(static_cast<uintptr_t>(exported.hardware_buffer));
                    AHardwareBuffer_Desc desc{};
                    AHardwareBuffer_describe(target->buffer, &desc);
                    target->buffer_width = static_cast<int>(desc.width); target->buffer_height = static_cast<int>(desc.height);
                }
                if (render_result < 0 && (ticket.flags & QUEST_MPV_HAS_IMAGE) && ticket.source_epoch > 0 &&
                    ticket.source_epoch < epoch_floor.load()) {
                    // VO can request a retained old redraw after RESET. Its
                    // codec buffer is already invalid; discard it, never mark
                    // its pixels valid or publish it as a new source image.
                    std::lock_guard<std::mutex> lock(frames_mutex);
                    target->phase = Phase::free; drop_image(*target); stale_seek_frames_discarded.fetch_add(1);
                    continue;
                }
                checked(render_result, "MPV immutable color render"); rendered.fetch_add(1);
                const uint64_t required = QUEST_MPV_HAS_IMAGE | QUEST_MPV_PTS_VALID | QUEST_MPV_RENDER_VALID;
                const bool valid = (ticket.flags & required) == required && ticket.source_epoch > 0 &&
                    ticket.frame_id > 0 && ticket.media_pts_us >= 0 && ticket.media_pts_us <= std::numeric_limits<int64_t>::max()/1000;
                std::lock_guard<std::mutex> lock(frames_mutex);
                if (!valid || closing.load()) { invalid_frames.fetch_add(!valid); target->phase = Phase::free; drop_image(*target); continue; }
                // The EOF redraw names the last source frame. In direct mode it has no image of its own and
                // is skipped below, so record it first: otherwise EOF never resolves and looping stalls.
                if (final_render && direct_render && !target->image && core_eof.load() && ticket.source_epoch >= epoch_floor.load())
                    final_ticket = ticket;
                // A redraw of a frame already exported has no image of its own: nothing new to publish.
                if (direct_render && !target->image) { target->phase = Phase::free; continue; }
                const bool default_crop = ticket.crop_x0 == 0 && ticket.crop_y0 == 0 && ticket.crop_x1 == 0 && ticket.crop_y1 == 0;
                const bool full_crop = ticket.crop_x0 == 0 && ticket.crop_y0 == 0 && ticket.crop_x1 == width && ticket.crop_y1 == height;
                require(ticket.width == width && ticket.height == height && ticket.rotation_degrees == 0 && (default_crop || full_crop),
                        "MPV transformed source needs an explicit format mapping before publication");
                auto observed_epoch = last_epoch.load();
                while (observed_epoch < ticket.source_epoch &&
                       !last_epoch.compare_exchange_weak(observed_epoch, ticket.source_epoch)) {}
                if (final_render && core_eof.load() && ticket.source_epoch >= epoch_floor.load()) {
                    glFlush(); final_ticket = ticket;
                }
                // A redraw may overwrite an unclaimed ready slot. Its valid
                // current image must remain available until acquired, including
                // keep-open EOF. Only suppress an image already consumed.
                if ((!forced && ticket.frame_id == last_acquired_id && ticket.source_epoch == last_acquired_epoch) ||
                    ticket.source_epoch < epoch_floor.load()) { target->phase = Phase::free; drop_image(*target); continue; }
                require(token_sequence < static_cast<uint64_t>(std::numeric_limits<int64_t>::max()), "MPV source lease counter exhausted");
                target->fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
                require(target->fence != nullptr && glGetError() == GL_NO_ERROR, "MPV producer completion fence failed");
                glFlush(); target->ticket = ticket; target->token = ++token_sequence; target->allow_repeat = forced;
                target->phase = Phase::ready; published.fetch_add(1);
                int64_t unset = -1; first_published_us.compare_exchange_strong(unset, startup_us());
            }
        } catch (const std::exception& failure) {
            { std::lock_guard<std::mutex> lock(frames_mutex); render_error = failure.what(); }
            render_failed.store(true); wake.notify_all();
        }
        if (renderer) { mpv_render_context_set_update_callback(renderer, nullptr, nullptr); mpv_render_context_free(renderer); }
        // Closing after failure also waits for any previously issued consumer leases.
        if (context != EGL_NO_CONTEXT && eglGetCurrentContext() == context) {
            while (!abandoned.load()) {
                bool held = false;
                try { std::lock_guard<std::mutex> lock(frames_mutex); poll_retirements(); held = consumer_holds(); }
                catch (...) { render_failed.store(true); break; }
                if (!held) break;
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
            { std::lock_guard<std::mutex> lock(frames_mutex);
                for (auto& slot : slots) {
                    if (slot.fence) glDeleteSync(slot.fence);
                    slot.fence = nullptr; glDeleteFramebuffers(1, &slot.fbo); glDeleteTextures(1, &slot.color);
                    slot.fbo = slot.color = 0; slot.phase = Phase::free; drop_image(slot);
                }
            }
            if (glGetError() != GL_NO_ERROR) render_failed.store(true);
            if (!eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)) render_failed.store(true);
        }
        if (surface != EGL_NO_SURFACE && !eglDestroySurface(display, surface)) render_failed.store(true);
        if (context != EGL_NO_CONTEXT && !eglDestroyContext(display, context)) render_failed.store(true);
        if (library) dlclose(library);
        // The EGL display belongs to Godot: never eglTerminate it here.
    }
    std::string acquire_frame() {
        owner(); if (closing.load() || render_failed.load()) return "";
        std::lock_guard<std::mutex> lock(frames_mutex);
        if (closing.load() || render_failed.load()) return "";
        Slot* newest = nullptr;
        for (auto& slot : slots) if (slot.phase == Phase::ready && slot.token > last_acquired_token &&
                                    slot.ticket.source_epoch >= epoch_floor.load() &&
                                    (slot.allow_repeat || slot.ticket.frame_id != last_acquired_id || slot.ticket.source_epoch != last_acquired_epoch)) {
            const auto result = glClientWaitSync(slot.fence, 0, 0);
            require(result != GL_WAIT_FAILED, "MPV shared producer fence cannot be observed by Godot");
            if ((result == GL_ALREADY_SIGNALED || result == GL_CONDITION_SATISFIED) &&
                (!newest || slot.token > newest->token)) newest = &slot;
        }
        if (!newest) return "";
        glDeleteSync(newest->fence); newest->fence = nullptr;
        require(glIsTexture(newest->color), "MPV shared texture is invisible in Godot context");
        newest->phase = Phase::acquired; last_acquired_token = newest->token; acquired.fetch_add(1);
#ifndef NDEBUG
        if ((last_acquired_id != newest->ticket.frame_id || last_acquired_epoch != newest->ticket.source_epoch) &&
            debug_step_active.exchange(false)) debug_step_images.fetch_add(1);
#endif
        last_acquired_id = newest->ticket.frame_id; last_acquired_epoch = newest->ticket.source_epoch;
        const auto& t = newest->ticket;
        return "{\"producer_token\":" + std::to_string(newest->token) + ",\"color_texture_id\":" + std::to_string(newest->color) +
            ",\"frame_id\":" + std::to_string(t.frame_id) + ",\"pts_us\":" + std::to_string(t.media_pts_us) +
            ",\"source_epoch\":" + std::to_string(t.source_epoch) + ",\"render_sequence\":" + std::to_string(t.render_sequence) +
            ",\"source_flags\":" + std::to_string(t.flags) +
            ",\"width\":" + std::to_string(newest->image ? t.width : newest->out_width) +
            ",\"height\":" + std::to_string(newest->image ? t.height : newest->out_height) +
            ",\"source_width\":" + std::to_string(t.width) + ",\"source_height\":" + std::to_string(t.height) +
            ",\"source_crop\":[" + std::to_string(t.crop_x0) + "," + std::to_string(t.crop_y0) + "," + std::to_string(t.crop_x1) + "," + std::to_string(t.crop_y1) +
            "],\"rotation_degrees\":" + std::to_string(t.rotation_degrees) +
            ",\"color_target\":\"" + std::string(newest->image ? "AHardwareBuffer" : "GL_TEXTURE_2D") +
            "\",\"color_format\":\"" + std::string(newest->image ? "decoder" : "GL_RGBA8") + "\"" +
            // Signed: tagged ARM64 pointers (top byte 0xb4) overflow a JSON reader's Long otherwise.
            (newest->image ? ",\"hardware_buffer\":" + std::to_string(static_cast<int64_t>(reinterpret_cast<uintptr_t>(newest->buffer))) +
                ",\"buffer_width\":" + std::to_string(newest->buffer_width) + ",\"buffer_height\":" + std::to_string(newest->buffer_height) : std::string()) +
            ",\"owner_context_shared\":true,\"producer_fence_ready\":true," +
            "\"source_ticket_valid\":true,\"immutable_color_frame\":true,\"coords\":\"top-left; MPV FLIP_Y=0\"}";
    }
    bool release_frame(uint64_t token) {
        owner(); std::lock_guard<std::mutex> lock(frames_mutex);
        for (auto& slot : slots) if (slot.token == token && slot.phase == Phase::acquired) {
            // Called after the last consumer command, including a copy or engine draw.
            slot.fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
            require(slot.fence != nullptr, "MPV consumer release fence unavailable");
            glFlush(); slot.phase = Phase::retiring; released.fetch_add(1); wake.notify_one(); return true;
        }
        return false;
    }
    void frame_code(uint64_t token, unsigned char* output) {
        owner(); std::lock_guard<std::mutex> lock(frames_mutex);
        const Slot* selected = nullptr;
        for (auto& slot : slots) if (slot.token == token && slot.phase == Phase::acquired) selected = &slot;
        require(selected && selected->ticket.width == 1280 && selected->ticket.height == 640,
                "Code samples require a held 1280x640 identity fixture");
        GLint read_fbo = 0, pack = 0, alignment = 0, row_length = 0, skip_rows = 0, skip_pixels = 0;
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read_fbo); glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &pack);
        glGetIntegerv(GL_PACK_ALIGNMENT, &alignment); glGetIntegerv(GL_PACK_ROW_LENGTH, &row_length);
        glGetIntegerv(GL_PACK_SKIP_ROWS, &skip_rows); glGetIntegerv(GL_PACK_SKIP_PIXELS, &skip_pixels);
        GLuint fbo = 0; glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo);
        glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, selected->color, 0);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0); glPixelStorei(GL_PACK_ALIGNMENT, 1); glPixelStorei(GL_PACK_ROW_LENGTH, 0);
        glPixelStorei(GL_PACK_SKIP_ROWS, 0); glPixelStorei(GL_PACK_SKIP_PIXELS, 0);
        const bool complete = glCheckFramebufferStatus(GL_READ_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
        if (complete) {
            // One diagnostic scanline avoids 24 separate mobile tile resolves.
            // Only the same 24 centers are returned; no full-frame CPU copy.
            std::array<unsigned char, 1280*4> row{};
            glReadPixels(0, 96, 1280, 1, GL_RGBA, GL_UNSIGNED_BYTE, row.data());
            for (int eye = 0; eye < 2; ++eye) for (int bit = 0; bit < 12; ++bit)
                for (int channel = 0; channel < 4; ++channel)
                    output[(eye*12+bit)*4+channel] = row[(eye*640+36+bit*50)*4+channel];
        }
        const auto status = glGetError();
        glBindFramebuffer(GL_READ_FRAMEBUFFER, read_fbo); glDeleteFramebuffers(1, &fbo);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, pack); glPixelStorei(GL_PACK_ALIGNMENT, alignment);
        glPixelStorei(GL_PACK_ROW_LENGTH, row_length); glPixelStorei(GL_PACK_SKIP_ROWS, skip_rows); glPixelStorei(GL_PACK_SKIP_PIXELS, skip_pixels);
        require(complete && status == GL_NO_ERROR, "Shared source calibration readback failed");
    }
    std::string status() {
        std::string snapshot, state_copy, error_copy, render_error_copy, final_copy = "null"; int held = 0, retiring = 0;
        { std::lock_guard<std::mutex> lock(status_mutex); snapshot = details; state_copy = state; error_copy = error; }
        { std::lock_guard<std::mutex> lock(frames_mutex); render_error_copy = render_error;
            if (core_eof.load() && final_ticket.frame_id > 0 && final_ticket.source_epoch >= epoch_floor.load())
                final_copy = "{\"source_epoch\":" + std::to_string(final_ticket.source_epoch) +
                    ",\"frame_id\":" + std::to_string(final_ticket.frame_id) + ",\"pts_us\":" + std::to_string(final_ticket.media_pts_us) +
                    ",\"render_sequence\":" + std::to_string(final_ticket.render_sequence) + "}";
            for (auto& slot : slots) { held += slot.phase == Phase::acquired; retiring += slot.phase == Phase::retiring; }
        }
        return "{\"backend\":\"Android_libmpv\",\"state\":" + quote(state_copy) + ",\"error\":" + quote(error_copy) +
            ",\"render_error\":" + quote(render_error_copy) + ",\"done\":" + (done.load() ? "true" : "false") +
            ",\"render_failed\":" + (render_failed.load() ? "true" : "false") + ",\"closing\":" + (closing.load() ? "true" : "false") +
            ",\"rendered\":" + std::to_string(rendered.load()) + ",\"published\":" + std::to_string(published.load()) +
            ",\"skipped\":" + std::to_string(skipped.load()) + ",\"acquired\":" + std::to_string(acquired.load()) +
            ",\"released\":" + std::to_string(released.load()) + ",\"held_slots\":" + std::to_string(held) +
            ",\"last_source_epoch\":" + std::to_string(last_epoch.load()) + ",\"epoch_floor\":" + std::to_string(epoch_floor.load()) +
            ",\"seeks_started\":" + std::to_string(seeks_started.load()) + ",\"seeks_completed\":" + std::to_string(seeks_completed.load()) +
            ",\"seek_mode\":" + quote(last_seek_exact.load() ? "exact" : "speed") +
            ",\"startup_native\":{\"scope\":\"elapsed_us_since_source_creation\",\"initialized_us\":" + std::to_string(initialized_us.load()) +
            ",\"renderer_ready_us\":" + std::to_string(renderer_ready_us.load()) + ",\"load_submitted_us\":" + std::to_string(load_submitted_us.load()) +
            ",\"file_loaded_us\":" + std::to_string(file_loaded_us.load()) + ",\"first_published_us\":" + std::to_string(first_published_us.load()) + "}" +
            ",\"invalid_frames\":" + std::to_string(invalid_frames.load()) +
            ",\"stale_seek_frames_discarded\":" + std::to_string(stale_seek_frames_discarded.load()) +
            ",\"audio_commands_applied\":" + std::to_string(audio_commands_applied.load()) +
            ",\"frame_cap_fps\":" + std::to_string(max_fps.load()) +
            ",\"max_output_width\":" + std::to_string(max_output_width.load()) +
            ",\"cadence_skipped\":" + std::to_string(cadence_skipped.load()) +
            ",\"cadence_untimed\":" + std::to_string(cadence_untimed.load()) +
            ",\"cadence_target_ns\":" + (cadence_target_ns.load() ? "true" : "false") +
#ifndef NDEBUG
            ",\"debug_steps_applied\":" + std::to_string(debug_steps_applied.load()) +
            ",\"debug_step_images\":" + std::to_string(debug_step_images.load()) +
#endif
            ",\"eof_source_resolved\":" + (final_copy == "null" ? "false" : "true") + ",\"eof_source_ticket\":" + final_copy +
            ",\"retiring_slots\":" + std::to_string(retiring) + ",\"details\":" + snapshot + "}";
    }
};
std::mutex registry_mutex;
std::unordered_map<jlong, std::shared_ptr<Source>> registry;
jlong next_handle = 0;
std::shared_ptr<Source> find(jlong handle) {
    std::lock_guard<std::mutex> lock(registry_mutex);
    const auto it = registry.find(handle); require(it != registry.end(), "Unknown MPV source handle"); return it->second;
}
void error(JNIEnv* env, const std::exception& failure) {
    if (!env->ExceptionCheck()) { auto type = env->FindClass("java/lang/IllegalStateException"); if (type) env->ThrowNew(type, failure.what()); }
}
}

extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_MpvSourceNative_available(JNIEnv*, jclass) { return extension_available() ? JNI_TRUE : JNI_FALSE; }
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_MpvSourceNative_create(JNIEnv* env, jclass, jobject context, jstring path, jint start,
                                                         jboolean hardware, jboolean audio, jint max_width, jobjectArray audio_files,
                                                         jobjectArray subtitle_files, jboolean exact_start) {
    try {
        require(extension_available(), "MPV source requires the verified private source-frame build");
        require(path && start >= 0, "Invalid MPV local source request");
        quest_mpv_initialize_android(env, context);
        const char* utf = env->GetStringUTFChars(path, nullptr); require(utf != nullptr, "MPV local path unavailable");
        std::string file = utf; env->ReleaseStringUTFChars(path, utf);
        const bool local = !file.empty() && file.front() == '/';
        const bool descriptor = file.rfind("fd://", 0) == 0 && file.size() > 5 && file.find_first_not_of("0123456789", 5) == std::string::npos;
        // Network library sources: the loopback SMB proxy and LAN DLNA servers (plain HTTP media URLs).
        const bool network = (file.rfind("http://", 0) == 0 || file.rfind("https://", 0) == 0) &&
            file.find_first_of(" \r\n") == std::string::npos;
        require(local || descriptor || network, "MPV source requires a local path, owned descriptor or HTTP media URL");
        require(max_width >= 0 && max_width <= 8192, "MPV output width cap out of range");
        // Alternating location/title; locations follow the same rules as the video itself.
        auto read_tracks = [env](jobjectArray files) {
            std::vector<std::pair<std::string, std::string>> extra;
            const jsize items = files ? env->GetArrayLength(files) : 0;
            require(items % 2 == 0 && items <= 16, "MPV extra track list must be location/title pairs");
            for (jsize i = 0; i < items; i += 2) {
                std::array<std::string, 2> pair;
                for (int k = 0; k < 2; ++k) {
                    auto* item = static_cast<jstring>(env->GetObjectArrayElement(files, i + k));
                    require(item != nullptr, "MPV extra track entry missing");
                    const char* chars = env->GetStringUTFChars(item, nullptr); require(chars != nullptr, "MPV extra track text unavailable");
                    pair[k] = chars; env->ReleaseStringUTFChars(item, chars); env->DeleteLocalRef(item);
                }
                const auto& where = pair[0];
                const bool ok = (!where.empty() && where.front() == '/') ||
                    (where.rfind("fd://", 0) == 0 && where.size() > 5 && where.find_first_not_of("0123456789", 5) == std::string::npos) ||
                    ((where.rfind("http://", 0) == 0 || where.rfind("https://", 0) == 0) && where.find_first_of(" \r\n") == std::string::npos);
                require(ok, "MPV extra track requires a local path, owned descriptor or HTTP URL");
                extra.emplace_back(pair[0], pair[1]);
            }
            return extra;
        };
        auto source = std::make_shared<Source>(file, hardware == JNI_TRUE, audio == JNI_TRUE, start,
            read_tracks(audio_files), read_tracks(subtitle_files), exact_start == JNI_TRUE);
        source->max_output_width.store(max_width); // before any render; fixed for this source
        std::lock_guard<std::mutex> lock(registry_mutex);
        require(registry.size() < 2 && next_handle < std::numeric_limits<jlong>::max(), "MPV source capacity exhausted");
        const auto id = ++next_handle; source->start(); registry.emplace(id, std::move(source)); return id;
    } catch (const std::exception& failure) { error(env, failure); return 0; }
}
extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_MpvSourceNative_acquire(JNIEnv* env, jclass, jlong handle) {
    try { return env->NewStringUTF(find(handle)->acquire_frame().c_str()); }
    catch (const std::exception& failure) { error(env, failure); return nullptr; }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_MpvSourceNative_release(JNIEnv* env, jclass, jlong handle, jlong token) {
    try { require(token > 0, "MPV producer lease invalid"); return find(handle)->release_frame(token) ? JNI_TRUE : JNI_FALSE; }
    catch (const std::exception& failure) { error(env, failure); return JNI_FALSE; }
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_MpvSourceNative_setPlaying(JNIEnv* env, jclass, jlong handle, jboolean playing) {
    try { auto source = find(handle); std::lock_guard<std::mutex> lock(source->commands_mutex);
        if (!source->closing.load()) { source->desired_play = playing == JNI_TRUE; source->playing_dirty = true; }
    } catch (const std::exception& failure) { error(env, failure); }
}
#ifndef NDEBUG
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_MpvMotionDiagnostics_stepFrame(JNIEnv* env, jclass, jlong handle) {
    try {
        auto source = find(handle);
        std::lock_guard<std::mutex> lock(source->commands_mutex);
        if (source->closing.load() || source->render_failed.load() || source->core_eof.load() ||
            source->desired_play || source->playing_dirty || source->pending_seek_ms >= 0 ||
            source->acquired.load() == 0 || source->released.load() != source->acquired.load() ||
            source->debug_steps_applied.load() >= 180 || source->debug_step_active.exchange(true)) return JNI_FALSE;
        source->debug_step_pending = true; source->wake.notify_one(); return JNI_TRUE;
    } catch (const std::exception& failure) { error(env, failure); return JNI_FALSE; }
}
#endif
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_MpvSourceNative_setAudio(JNIEnv* env, jclass, jlong handle, jint track, jdouble volume, jboolean muted) {
    try {
        if (track < -1 || !std::isfinite(volume) || volume < 0 || volume > 100) return JNI_FALSE;
        auto source = find(handle); std::lock_guard<std::mutex> lock(source->commands_mutex);
        if (source->closing.load() || !source->audio ||
            (track > 0 && std::find(source->audio_track_ids.begin(), source->audio_track_ids.end(), track) == source->audio_track_ids.end())) return JNI_FALSE;
        source->desired_audio_id = track; source->desired_volume = volume; source->desired_mute = muted == JNI_TRUE;
        source->audio_dirty = true; source->wake.notify_one(); return JNI_TRUE;
    } catch (const std::exception& failure) { error(env, failure); return JNI_FALSE; }
}
extern "C" JNIEXPORT jlong JNICALL
Java_org_vrpassthroughplayer_plugin_MpvSourceNative_setSubtitle(JNIEnv* env, jclass, jlong handle, jint track) {
    try {
        if (track < -1) return 0;
        auto source = find(handle); std::lock_guard<std::mutex> lock(source->commands_mutex);
        if (source->closing.load() || source->subtitle_requests >= static_cast<uint64_t>(std::numeric_limits<jlong>::max()) ||
            (track > 0 && std::find(source->subtitle_track_ids.begin(), source->subtitle_track_ids.end(), track) == source->subtitle_track_ids.end())) return 0;
        source->desired_subtitle_id = track;
        source->desired_subtitle_command = ++source->subtitle_requests;
        source->subtitle_dirty = true; source->wake.notify_one();
        return static_cast<jlong>(source->desired_subtitle_command);
    } catch (const std::exception& failure) { error(env, failure); return 0; }
}
extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_MpvSourceNative_subtitleStatus(JNIEnv* env, jclass, jlong handle, jlong after_sequence) {
    try {
        require(after_sequence >= 0, "MPV subtitle sequence invalid");
        auto source = find(handle); std::lock_guard<std::mutex> lock(source->status_mutex);
        if (source->published_subtitle_sequence <= static_cast<uint64_t>(after_sequence)) return env->NewStringUTF("");
        const auto now = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
        auto json = source->subtitle_snapshot;
        json.pop_back();
        json += ",\"age_ms\":" + std::to_string(std::max<int64_t>(0, (now-source->published_subtitle_ns)/1000000)) + "}";
        return env->NewStringUTF(json.c_str());
    } catch (const std::exception& failure) { error(env, failure); return nullptr; }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_MpvSourceNative_seek(JNIEnv* env, jclass, jlong handle, jlong position, jboolean exact) {
    try {
        require(position >= 0 && position <= std::numeric_limits<int32_t>::max(), "MPV seek position out of range");
        auto source = find(handle); std::lock_guard<std::mutex> lock(source->commands_mutex);
        const auto epoch = source->last_epoch.load();
        if (source->closing.load() || epoch == 0 || source->epoch_floor.load() > epoch) return JNI_FALSE;
        source->epoch_floor.store(epoch+1); source->core_eof.store(false);
        source->pending_seek_ms = position; source->pending_seek_exact = exact == JNI_TRUE;
        source->wake.notify_one(); return JNI_TRUE;
    } catch (const std::exception& failure) { error(env, failure); return JNI_FALSE; }
}
extern "C" JNIEXPORT jstring JNICALL
Java_org_vrpassthroughplayer_plugin_MpvSourceNative_status(JNIEnv* env, jclass, jlong handle) {
    try { return env->NewStringUTF(find(handle)->status().c_str()); }
    catch (const std::exception& failure) { error(env, failure); return nullptr; }
}
// Direct mode: publish the decoder's exported images (Alpha). Takes effect on the next render.
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_MpvSourceNative_setDirect(JNIEnv* env, jclass, jlong handle, jboolean enabled) {
    try { find(handle)->direct.store(enabled == JNI_TRUE); }
    catch (const std::exception& failure) { error(env, failure); }
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_MpvSourceNative_setFrameCap(JNIEnv* env, jclass, jlong handle, jint fps) {
    try {
        require(fps >= 0 && fps <= 240, "MPV frame cap out of range");
        auto source = find(handle);
        if (source->max_fps.exchange(fps) != fps) { source->cadence_reset.store(true); source->wake.notify_one(); }
    } catch (const std::exception& failure) { error(env, failure); }
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_MpvSourceNative_requestFrame(JNIEnv* env, jclass, jlong handle) {
    try { auto source = find(handle); source->force_redraw.store(true); source->wake.notify_one(); }
    catch (const std::exception& failure) { error(env, failure); }
}
extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_MpvSourceNative_readFrameCode(JNIEnv* env, jclass, jlong handle, jlong token, jobject output) {
    try {
        require(token > 0 && output && env->GetDirectBufferCapacity(output) == 96, "Exact-size calibration output required");
        auto* data = static_cast<unsigned char*>(env->GetDirectBufferAddress(output)); require(data, "Calibration direct buffer unavailable");
        auto type = env->GetObjectClass(output); auto readonly = env->GetMethodID(type, "isReadOnly", "()Z");
        require(readonly && !env->CallBooleanMethod(output, readonly) && !env->ExceptionCheck(), "Writable calibration buffer required");
        env->DeleteLocalRef(type); find(handle)->frame_code(token, data);
    } catch (const std::exception& failure) { error(env, failure); }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_org_vrpassthroughplayer_plugin_MpvSourceNative_close(JNIEnv* env, jclass, jlong handle, jboolean abandon) {
    try {
        auto source = find(handle); source->closing.store(true);
        if (abandon == JNI_TRUE) source->abandoned.store(true);
        source->wake.notify_all(); if (!source->done.load()) return JNI_FALSE;
        std::lock_guard<std::mutex> lock(registry_mutex); registry.erase(handle); return JNI_TRUE;
    } catch (const std::exception& failure) { error(env, failure); return JNI_FALSE; }
}

extern "C" JNIEXPORT void JNICALL
Java_org_vrpassthroughplayer_plugin_MpvSourceNative_requestClose(JNIEnv* env, jclass, jlong handle) {
    try { auto source = find(handle); source->closing.store(true); source->wake.notify_all(); }
    catch (const std::exception& failure) { error(env, failure); }
}
