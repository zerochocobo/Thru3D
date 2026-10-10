#ifndef QUEST_PGS_BITMAP_H
#define QUEST_PGS_BITMAP_H
#include <mpv/quest_subtitle.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace quest {
struct PgsImage {
    int x = 0, y = 0, width = 0, height = 0, canvas_width = 0, canvas_height = 0;
    std::vector<uint8_t> rgba; // top-first, premultiplied RGBA; only the occupied crop
};
inline PgsImage compose_pgs(const quest_mpv_pgs_frame& frame) {
    PgsImage out;
    if (frame.canvas_width < 1 || frame.canvas_height < 1 ||
        frame.canvas_width > 4096 || frame.canvas_height > 4096 ||
        frame.num_parts < 0 || frame.num_parts > 64 || (frame.num_parts && !frame.parts))
        throw std::runtime_error("Invalid PGS canvas");
    out.canvas_width = frame.canvas_width; out.canvas_height = frame.canvas_height;
    int x0 = frame.canvas_width, y0 = frame.canvas_height, x1 = 0, y1 = 0;
    for (int i = 0; i < frame.num_parts; ++i) {
        const auto& p = frame.parts[i];
        if (!p.bgra || p.width < 1 || p.height < 1 || p.width > 8192 || p.height > 8192 ||
            p.stride < static_cast<int64_t>(p.width) * 4 || p.display_width < 1 || p.display_height < 1)
            throw std::runtime_error("Invalid PGS part");
        const auto right = static_cast<int64_t>(p.x) + p.display_width;
        const auto bottom = static_cast<int64_t>(p.y) + p.display_height;
        x0 = std::min(x0, std::max(0, p.x)); y0 = std::min(y0, std::max(0, p.y));
        x1 = std::max(x1, static_cast<int>(std::clamp<int64_t>(right, 0, frame.canvas_width)));
        y1 = std::max(y1, static_cast<int>(std::clamp<int64_t>(bottom, 0, frame.canvas_height)));
    }
    if (x1 <= x0 || y1 <= y0) return out;
    out.x = x0; out.y = y0; out.width = x1-x0; out.height = y1-y0;
    if (static_cast<int64_t>(out.width)*out.height*4 > 16*1024*1024)
        throw std::runtime_error("PGS crop exceeds transfer budget");
    out.rgba.resize(static_cast<size_t>(out.width)*out.height*4);
    for (int i = 0; i < frame.num_parts; ++i) {
        const auto& p = frame.parts[i];
        const int right = static_cast<int>(std::clamp<int64_t>(static_cast<int64_t>(p.x)+p.display_width, 0, x1));
        const int bottom = static_cast<int>(std::clamp<int64_t>(static_cast<int64_t>(p.y)+p.display_height, 0, y1));
        for (int y = std::max(y0,p.y); y < bottom; ++y) for (int x = std::max(x0,p.x); x < right; ++x) {
            const double sx = std::clamp((static_cast<double>(x)-p.x+0.5)*p.width/p.display_width-0.5, 0.0, static_cast<double>(p.width-1));
            const double sy = std::clamp((static_cast<double>(y)-p.y+0.5)*p.height/p.display_height-0.5, 0.0, static_cast<double>(p.height-1));
            const int ax = static_cast<int>(sx), ay = static_cast<int>(sy);
            const int bx = std::min(ax+1,p.width-1), by = std::min(ay+1,p.height-1);
            const double fx = sx-ax, fy = sy-ay;
            double pixel[4];
            for (int c = 0; c < 4; ++c) {
                const auto at = [&](int px, int py) { return p.bgra[static_cast<size_t>(py)*p.stride+px*4+c]; };
                pixel[c] = (at(ax,ay)*(1-fx)+at(bx,ay)*fx)*(1-fy) + (at(ax,by)*(1-fx)+at(bx,by)*fx)*fy;
            }
            auto* dest = out.rgba.data()+(static_cast<size_t>(y-y0)*out.width+x-x0)*4;
            const double remaining = 1-pixel[3]/255;
            for (int c = 0; c < 4; ++c) {
                const double source = pixel[c == 0 ? 2 : (c == 2 ? 0 : c)];
                dest[c] = static_cast<uint8_t>(std::clamp(std::lround(source+dest[c]*remaining),0L,255L));
            }
        }
    }
    return out;
}
}
#endif
