// Host test of the 2D->3D near-map stabilizer (native/rvm/depth_stabilizer.cpp).
// Build (Windows): tools/Test-DepthStabilizer.ps1
#include "../../native/rvm/depth_stabilizer.h"

#include <cmath>
#include <cstdio>
#include <random>
#include <vector>

using quest::DepthStabilizer;
static int failures = 0, checks = 0;
static void check(bool ok, const char* what) {
    ++checks;
    if (!ok) { ++failures; std::printf("FAIL: %s\n", what); }
}

static std::vector<float> texture(int w, int h, unsigned seed, int ox = 0, int oy = 0) {
    // Smooth random texture sampled at an offset, so shifted copies are exact translations.
    std::mt19937 rng(seed);
    std::uniform_real_distribution<float> u(0.f, 1.f);
    const int W = w + 64, H = h + 64;
    std::vector<float> noise(static_cast<size_t>(W) * H);
    for (auto& v : noise) v = u(rng);
    std::vector<float> out(static_cast<size_t>(w) * h);
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
        float acc = 0;
        for (int dy = 0; dy < 4; ++dy) for (int dx = 0; dx < 4; ++dx) acc += noise[(y + 32 - oy + dy) * W + (x + 32 - ox + dx)];
        out[y * w + x] = acc / 16.f;
    }
    return out;
}

int main() {
    const int w = 252, h = 140;
    // Phase correlation recovers a translation (b(x) = a(x - d)).
    {
        const int sw = 126, sh = 70;
        auto a = texture(sw, sh, 1, 0, 0), b = texture(sw, sh, 1, 3, -2);
        float dx = 0, dy = 0, r = 0;
        DepthStabilizer::phase_correlate(a, b, sw, sh, &dx, &dy, &r);
        std::printf("phase correlate: dx=%.2f dy=%.2f response=%.3f\n", dx, dy, r);
        check(std::fabs(dx - 3.f) < 0.6f && std::fabs(dy + 2.f) < 0.6f, "phase correlation finds (3, -2)");
        check(r > 0.05f, "phase correlation response above the gate");
        auto c = texture(sw, sh, 99);
        DepthStabilizer::phase_correlate(a, c, sw, sh, &dx, &dy, &r);
        check(r < 0.05f + 0.15f, "unrelated images give a weak response");
    }
    const size_t n = static_cast<size_t>(w) * h;
    std::vector<float> rgb(3 * n), inv(n), near(n);
    auto scene = [&](float shade, unsigned seed) {
        auto t = texture(w, h, seed);
        for (size_t p = 0; p < n; ++p) { rgb[p] = 0.2f + 0.6f * t[p] * shade; rgb[n + p] = 0.3f * t[p]; rgb[2 * n + p] = 0.5f * shade; }
    };
    // A person-like near blob over a far background.
    auto depth = [&](float noise_amp, unsigned seed) {
        std::mt19937 rng(seed);
        std::normal_distribution<float> g(0.f, 1.f);
        for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
            const float dxn = (x - 126) / 40.f, dyn = (y - 80) / 50.f;
            const float blob = dxn * dxn + dyn * dyn < 1 ? 1.f : 0.f;
            inv[y * w + x] = 1.f + 4.f * blob + 0.5f * y / h + noise_amp * g(rng);
        }
    };
    // First frame: normalized, foreground near 1, background near 0.
    {
        DepthStabilizer s(w, h);
        scene(1.f, 7); depth(0.f, 1);
        s.process(inv.data(), rgb.data(), 1, near.data());
        check(near[80 * w + 126] > 0.95f && near[5 * w + 5] < 0.1f, "first frame: foreground near, background far");
    }
    // Static scene whose wall drifts in level frame to frame (the depth "swimming" the VVPS base
    // stabilizer targets) while the rest of the depth distribution stays: the wall is steadier.
    {
        DepthStabilizer stable(w, h);
        scene(1.f, 7);
        std::vector<float> ns, nr;
        for (int f = 0; f < 60; ++f) {
            const float wob = 0.25f * std::sin(f * 1.7f);
            for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x)
                inv[y * w + x] = x < w / 2 ? 2.f + wob : 1.f + 2.f * y / h;
            stable.process(inv.data(), rgb.data(), 1, near.data());
            const float s_val = near[70 * w + 60];
            DepthStabilizer fresh(w, h);
            fresh.process(inv.data(), rgb.data(), 1, near.data());
            if (f >= 20) { ns.push_back(s_val); nr.push_back(near[70 * w + 60]); }
        }
        double mean_s = 0, mean_r = 0, var_s = 0, var_r = 0;
        for (float v : ns) mean_s += v;
        for (float v : nr) mean_r += v;
        mean_s /= ns.size(); mean_r /= nr.size();
        for (float v : ns) var_s += (v - mean_s) * (v - mean_s);
        for (float v : nr) var_r += (v - mean_r) * (v - mean_r);
        std::printf("wall level flicker: stabilized var %.5f, per-frame var %.5f\n", var_s, var_r);
        check(var_s < 0.5 * var_r, "VVPS halves the wall's level flicker");
    }
    // Scene cut: a different shot resets (and is reported).
    {
        DepthStabilizer s(w, h);
        depth(0.f, 1);
        scene(1.f, 7);
        for (int f = 0; f < 5; ++f) s.process(inv.data(), rgb.data(), 1, near.data());
        check(!s.last_cut(), "same shot: no cut");
        for (size_t p = 0; p < n; ++p) { rgb[p] = 0.05f; rgb[n + p] = 0.6f; rgb[2 * n + p] = 0.9f; }
        s.process(inv.data(), rgb.data(), 1, near.data());
        check(s.last_cut(), "different colours: cut");
    }
    // Camera pan: the global shift is measured on the model input.
    {
        DepthStabilizer s(w, h);
        depth(0.f, 1);
        auto put = [&](int ox) {
            auto t = texture(w, h, 3, ox, 0);
            for (size_t p = 0; p < n; ++p) { rgb[p] = t[p]; rgb[n + p] = t[p]; rgb[2 * n + p] = t[p]; }
        };
        put(0); s.process(inv.data(), rgb.data(), 1, near.data());
        put(6); s.process(inv.data(), rgb.data(), 1, near.data());
        std::printf("pan: dx=%.2f dy=%.2f response=%.3f\n", s.last_dx(), s.last_dy(), s.last_response());
        check(std::fabs(s.last_dx() - 6.f) < 1.5f && std::fabs(s.last_dy()) < 1.f, "pan of 6 px measured");
    }
    std::printf("depth stabilizer checks=%d failures=%d\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
