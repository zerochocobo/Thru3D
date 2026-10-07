#pragma once

#include <array>
#include <cstddef>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

struct AHardwareBuffer;
namespace MNN { class Interpreter; class Session; class Tensor; }

namespace quest {
struct MnnRvmReport {
    int width = 0, height = 0;
    bool fp16 = true;
    int gpu_ops = 0;                     // ops whose outputs live on the OpenCL device
    std::vector<std::string> host_ops;   // any entry rejects the runtime (no CPU fallback)
    double prepare_ms = 0;
    bool cache_loaded = false;
    // Last successful stereo call, wall ms: validate, upload+run (enqueue), Alpha readback, state copy.
    std::array<double, 4> last_phase_ms{};
    uint64_t state_checks = 0, nonfinite_resets = 0; // zero-copy health checks
};

/** RVM ratio=1 (pha + four recurrent states) on MNN OpenCL. One session per eye and
 * stream; states stay on the device and are copied output->input only after both
 * eyes produced finite Alpha in [0, 1]. Stream 0 drives display; stream 1 is an
 * independent full-eye scout for ROI placement with its own recurrent states.
 * Not thread-safe. */
class MnnRvmBackend final {
public:
    MnnRvmBackend(const void* model, size_t bytes, int width, int height, bool fp16, const std::string& cache_file);
    ~MnnRvmBackend();
    MnnRvmBackend(const MnnRvmBackend&) = delete;
    MnnRvmBackend& operator=(const MnnRvmBackend&) = delete;
    static constexpr int kStreams = 2;
    void reset(int eye, int stream = 0);
    /** rgb: float32 CHW in [0, 1]; alpha: float32 HxW. Both eyes or neither advance.
     * reset_first zeroes this stream's states before inference (ROI window change). */
    void process_alpha_stereo(const std::array<const float*, 2>& rgb, const std::array<float*, 2>& alpha,
                              int stream = 0, bool reset_first = false);
    /** Zero-copy: RGBA8 AHardwareBuffers (width x height) in, Alpha as R of RGBA8 out (rounded
     * alpha*255). The GPU never hands pixels to the CPU. Returns false when a periodic state check
     * found nonfinite values; that stream was reset and the Alpha of this call must not be shown. */
    bool process_ahb(const std::array<AHardwareBuffer*, 2>& rgb, const std::array<AHardwareBuffer*, 2>& alpha,
                     int stream = 0, bool reset_first = false);
    const MnnRvmReport& report() const { return report_; }
    int width() const { return report_.width; }
    int height() const { return report_.height; }
private:
    struct Eye;
    void audit_placement();
    std::shared_ptr<MNN::Interpreter> net_;
    std::array<std::array<std::unique_ptr<Eye>, 2>, kStreams> eyes_;
    MnnRvmReport report_;
    std::string cache_file_;
    // Imported AHardwareBuffers keep their CL buffers on these tensors; keyed by buffer.
    std::unordered_map<AHardwareBuffer*, std::unique_ptr<MNN::Tensor>> shared_;
    std::array<uint64_t, kStreams> zero_copy_calls_{};
    MNN::Tensor* shared(AHardwareBuffer* buffer, const MNN::Tensor* like);
};
} // namespace quest
