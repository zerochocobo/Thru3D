// Standalone ARM64 MPV/PGS probe. No app install, UI, GPU renderer or OCR.
#include <mpv/client.h>
#include <mpv/quest_subtitle.h>
#include "../../native/mpv/pgs_bitmap.h"
#include <chrono>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>

static void checked(int result, const char* label) {
    if (result < 0) throw std::runtime_error(std::string(label)+": "+mpv_error_string(result));
}
struct Capture {
    quest::PgsImage image;
    int track = 0, parts = 0, changed = 0;
    bool failed = false;
};
static void capture(void* opaque, const quest_mpv_pgs_frame* frame) noexcept {
    auto& out = *static_cast<Capture*>(opaque);
    try {
        out.track = frame->track_id; out.parts = frame->num_parts; out.changed = frame->changed;
        out.image = quest::compose_pgs(*frame);
    } catch (...) { out.failed = true; }
}
static Capture read(mpv_handle* core) {
    double pts = 0;
    checked(mpv_get_property(core,"time-pos",MPV_FORMAT_DOUBLE,&pts),"clock");
    Capture out;
    checked(mpv_quest_get_pgs(core,1920,1080,pts,capture,&out),"PGS callback");
    if (out.failed) throw std::runtime_error("PGS composition failed");
    return out;
}
static void restart(mpv_handle* core, const char* seconds) {
    const char* command[] = {"seek",seconds,"absolute+exact",nullptr};
    checked(mpv_command(core,command),"seek");
    for (int n = 0; n < 500; ++n) {
        const auto* event = mpv_wait_event(core,0.01);
        if (event->event_id == MPV_EVENT_PLAYBACK_RESTART) return;
    }
    throw std::runtime_error("Seek restart timeout");
}
int main(int argc, char** argv) {
    if (argc != 3) return 2;
    mpv_handle* core = nullptr;
    try {
        if (mpv_quest_pgs_api_version() != QUEST_MPV_PGS_API_VERSION) throw std::runtime_error("PGS API mismatch");
        core = mpv_create();
        if (!core) throw std::runtime_error("MPV create failed");
        for (const auto& setting : {std::pair{"config","no"}, {"vo","null"}, {"hwdec","no"},
            {"audio","no"}, {"pause","yes"}, {"sid","1"}, {"sub-visibility","no"},
            {"start","84.5"}, {"keep-open","yes"}, {"terminal","no"}})
            checked(mpv_set_option_string(core,setting.first,setting.second),setting.first);
        checked(mpv_initialize(core),"initialize");
        const char* load[] = {"loadfile",argv[1],nullptr};
        checked(mpv_command(core,load),"load");
        bool ready = false;
        for (int n = 0; n < 1000; ++n) {
            const auto* event = mpv_wait_event(core,0.01);
            if (event->event_id == MPV_EVENT_PLAYBACK_RESTART) { ready = true; break; }
        }
        if (!ready) throw std::runtime_error("Load restart timeout");
        auto first = read(core);
        if (first.track != 1 || first.image.rgba.empty()) throw std::runtime_error("Real PGS cue missing");
        const std::string output = argv[2];
        std::ofstream raw(output+"/decoded.rgba",std::ios::binary);
        raw.write(reinterpret_cast<const char*>(first.image.rgba.data()), static_cast<std::streamsize>(first.image.rgba.size()));
        raw.close();
        double before = 0, after = 0;
        checked(mpv_get_property(core,"time-pos",MPV_FORMAT_DOUBLE,&before),"paused clock");
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        auto paused = read(core);
        checked(mpv_get_property(core,"time-pos",MPV_FORMAT_DOUBLE,&after),"paused clock");
        if (paused.changed || paused.image.rgba != first.image.rgba || before != after)
            throw std::runtime_error("Paused PGS pixels/clock changed");
        checked(mpv_set_property_string(core,"sid","2"),"second PGS track");
        Capture second;
        for (int n = 0; n < 100; ++n) {
            second = read(core);
            if (second.track == 2 && !second.image.rgba.empty()) break;
            mpv_wait_event(core,0.01);
        }
        if (second.track != 2 || second.image.rgba.empty()) throw std::runtime_error("Second PGS track missing");
        restart(core,"67");
        if (!read(core).image.rgba.empty()) throw std::runtime_error("PGS gap retained old image");
        restart(core,"84.5");
        if (read(core).image.rgba.empty()) throw std::runtime_error("PGS seek failed to restore image");
        checked(mpv_set_property_string(core,"sid","no"),"PGS off");
        if (!read(core).image.rgba.empty()) throw std::runtime_error("Disabled PGS retained image");
        std::ofstream report(output+"/verification.json");
        report << "{\"state\":\"passed\",\"track\":" << first.track << ",\"parts\":" << first.parts
               << ",\"x\":" << first.image.x << ",\"y\":" << first.image.y
               << ",\"width\":" << first.image.width << ",\"height\":" << first.image.height
               << ",\"byte_count\":" << first.image.rgba.size()
               << ",\"checks\":[\"real_PGS_palette\",\"paused_cue\",\"second_track\",\"seek_gap\",\"seek_restore\",\"off\"]}";
        report.close();
        std::cout << "Real ARM64 PGS decoding/paused/track/seek/gap/off checks passed\n";
        mpv_terminate_destroy(core);
        return 0;
    } catch (const std::exception& failure) {
        std::cerr << failure.what() << '\n';
        if (core) mpv_terminate_destroy(core);
        return 1;
    }
}
