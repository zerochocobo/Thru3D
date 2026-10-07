#pragma once

#include <cstdint>
#include <vector>

namespace quest {

/** 2D->3D near map from the depth model's relative inverse depth, ported from PTMediaServer's
 * realtime path (offline/two_dvr_gpu.py _GpuNearPreprocessor + two_dvr_render.py
 * TemporalDepthStabilizer, utils/scene_detection.py):
 *  1. scene cut (HSV hue/saturation histogram, Bhattacharyya) resets all state;
 *  2. 5/95 percentile band, smoothed across frames (reset on a jump of a whole band);
 *  3. VVPS stabilizer: only the low-frequency base (box, min(h,w)/16) is smoothed in time and
 *     the current frame's detail is always re-added; the previous base is first moved by the
 *     global shift (phase correlation) and blended per tile by the motion-compensated gray
 *     residual (evidence gate), after a bounded affine match;
 *  4. foreground dilated by round(w/512) px (soft_shift hole fill).
 * Pure C++ (no Android): host-testable. Not thread-safe.
 *
 * The PC path runs once per frame; here the model may skip frames. Every per-frame rate is
 * applied as 1 - (1 - a)^k for k source frames since the previous call, so time constants match. */
class DepthStabilizer {
public:
    DepthStabilizer(int width, int height);
    void reset();
    /** inv: model output (larger = nearer), w*h. rgb: the model input, float CHW in [0, 1].
     * frame_step: source frames since the previous call (>= 1). near: output w*h in [0, 1]. */
    void process(const float* inv, const float* rgb, int frame_step, float* near);
    bool last_cut() const { return last_cut_; }
    float last_dx() const { return last_dx_; }
    float last_dy() const { return last_dy_; }
    float last_response() const { return last_response_; }
    uint64_t cuts() const { return cuts_; }
    /** Foreground dilation radius in model pixels; negative restores the default round(w/512), >= 1. */
    void set_dilation(int radius) { dilation_ = radius; }

    // Parameters (PTMediaServer defaults).
    static constexpr float kNormAlpha = 0.10f, kNormReset = 1.0f;
    static constexpr float kDepthAlpha = 0.20f, kEvidenceLock = 0.5f;
    static constexpr float kAffineMaxScale = 0.20f, kAffineMaxBias = 0.12f;
    static constexpr float kMcMinResponse = 0.05f, kMcMaxShift = 96.0f;
    static constexpr float kEvidLo = 6.0f, kEvidHi = 36.0f;
    static constexpr float kCutThreshold = 0.4f, kCutRefEma = 0.95f;
    static constexpr int kCutCooldown = 24;

    // Exposed for tests: phase correlation of two equally sized float images (Hann windowed).
    // Returns the shift (dx, dy) that registers a onto b, b(x) ~ a(x - d); response in [0, 1].
    static void phase_correlate(const std::vector<float>& a, const std::vector<float>& b, int w, int h,
                                float* dx, float* dy, float* response);

private:
    int w_, h_, sw_, sh_;
    bool have_band_ = false, initialized_ = false, have_small_ = false;
    float lo_ = 0, hi_ = 1;
    std::vector<float> near_, base_cur_, base_prev_, base_warp_, tmp_, alpha_;
    std::vector<uint8_t> gray_;
    std::vector<float> small_cur_, small_prev_;
    // Scene cut detector.
    std::vector<float> ref_hist_;
    bool have_ref_ = false;
    int cooldown_left_ = 0;
    int dilation_ = -1;
    bool last_cut_ = false;
    float last_dx_ = 0, last_dy_ = 0, last_response_ = 0;
    uint64_t cuts_ = 0;

    bool scene_cut(const float* rgb, int frame_step);
    void band(const float* inv, int frame_step);
    void stabilize(const float* rgb, int frame_step);
};

} // namespace quest
