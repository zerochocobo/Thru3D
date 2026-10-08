#include "photo_depth.h"

#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <vector>

namespace quest {
void photo_near_map(const float* inverse, int width, int height,
                    int x, int y, int cw, int ch, float* near) {
    if (!inverse || !near || width < 1 || height < 1 || width > 1024 || height > 1024 ||
        x < 0 || y < 0 || cw < 1 || ch < 1 || cw > width || ch > height ||
        x > width - cw || y > height - ch)
        throw std::invalid_argument("Invalid photo depth content rectangle");
    constexpr float neutral = 0.35f;
    std::vector<float> values;
    values.reserve(static_cast<size_t>(cw) * ch);
    for (int row = y; row < y + ch; ++row) for (int col = x; col < x + cw; ++col) {
        const float value = inverse[row * width + col];
        if (std::isfinite(value)) values.push_back(value);
    }
    std::fill(near, near + static_cast<size_t>(width) * height, neutral);
    if (values.size() < 16) return;
    auto percentile = [&](float q) {
        auto nth = values.begin() + static_cast<long>(q * (values.size() - 1));
        std::nth_element(values.begin(), nth, values.end());
        return *nth;
    };
    const float lo = percentile(0.05f), hi = percentile(0.95f);
    if (!(hi - lo > 1e-6f) || !std::isfinite(hi - lo)) return;
    const float scale = 1.f / (hi - lo);
    std::vector<float> normalized(static_cast<size_t>(cw) * ch);
    for (int row = 0; row < ch; ++row) for (int col = 0; col < cw; ++col) {
        const float value = inverse[(y + row) * width + x + col];
        normalized[row * cw + col] = std::isfinite(value) ? std::clamp((value - lo) * scale, 0.f, 1.f) : neutral;
    }
    const int radius = std::max(1, static_cast<int>(std::lround(cw / 512.0)));
    for (int row = y; row < y + ch; ++row) for (int col = x; col < x + cw; ++col) {
        float value = 0;
        for (int dy = -radius; dy <= radius; ++dy) for (int dx = -radius; dx <= radius; ++dx)
            value = std::max(value, normalized[std::clamp(row - y + dy, 0, ch - 1) * cw + std::clamp(col - x + dx, 0, cw - 1)]);
        near[row * width + col] = value;
    }
    for (int row = 0; row < height; ++row) for (int col = 0; col < width; ++col)
        if (row < y || row >= y + ch || col < x || col >= x + cw)
            near[row * width + col] = near[std::clamp(row, y, y + ch - 1) * width + std::clamp(col, x, x + cw - 1)];
}
}
