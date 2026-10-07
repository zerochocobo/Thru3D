#pragma once

#ifdef __ANDROID__
#include <android/asset_manager.h>
#endif
#include <net.h>
#include <array>
#include <cstdint>
#include <memory>
#include <vector>
#include <string>

namespace quest {
struct TensorShape { int width; int height; int channels; };
struct RvmProfile {
    const char* key;
    const char* id;
    const char* param_asset;
    const char* bin_asset;
    const char* oracle_prefix;
    TensorShape rgb;
    std::array<TensorShape, 6> outputs;
};
const RvmProfile& find_profile(const std::string& key);

class GpuLease;
class ResidentGpuState;
enum class RvmPrecision { FP32, FP16Storage };
struct StateTransferStats {
    uint64_t rgb_upload_bytes = 0;
    uint64_t initial_state_upload_bytes = 0;
    uint64_t alpha_download_bytes = 0;
    uint64_t validation_upload_bytes = 0;
    uint64_t validation_download_bytes = 0;
    uint64_t committed_stereo_frames = 0;
    uint64_t diagnostic_state_download_bytes = 0;
};

// Optional wall-clock phases around a successful stereo call. Submission includes
// queue wait, transfers and GPU work; it is not a GPU timestamp measurement.
struct ResidentPhaseTiming {
    std::array<double, 7> phases_ms{};
    double total_ms = 0;
    bool completed = false;
};

/** Verified FP32 profiles. All four recurrent states are independent per eye. Not thread-safe. */
class RvmBackend final {
public:
#ifdef __ANDROID__
    RvmBackend(AAssetManager* assets, bool vulkan, const RvmProfile& profile = find_profile("256x144"),
               RvmPrecision precision = RvmPrecision::FP32);
#endif
    RvmBackend(const char* param, const char* bin, bool vulkan, const RvmProfile& profile,
               RvmPrecision precision = RvmPrecision::FP32);
    ~RvmBackend();
    RvmBackend(const RvmBackend&) = delete;
    RvmBackend& operator=(const RvmBackend&) = delete;
    void reset(int eye);
    std::array<ncnn::Mat, 6> process(int eye, const ncnn::Mat& rgb);
    // Advance both eyes only after every output and owned state allocation succeeds.
    std::array<std::array<ncnn::Mat, 6>, 2> process_stereo(const std::array<ncnn::Mat, 2>& rgb);
    // Production Vulkan path: resident states; read back Alpha and eight uint32 finite flags.
    std::array<ncnn::Mat, 2> process_alpha_stereo(const std::array<ncnn::Mat, 2>& rgb,
                                              ResidentPhaseTiming* timing = nullptr);
    const StateTransferStats& transfer_stats() const { return transfers_; }
    bool uses_vulkan() const { return net_.opt.use_vulkan_compute; }
    bool uses_half_storage() const { return precision_ == RvmPrecision::FP16Storage; }
    // Numerical oracle only; production never calls this state readback.
    std::array<std::array<ncnn::Mat, 4>, 2> snapshot_resident_states();
    const RvmProfile& profile() const { return profile_; }
    int layer_count() const;
    int vulkan_capable_layers() const;
    std::vector<std::string> non_vulkan_layers() const;
private:
    void configure(bool vulkan);
    std::array<ncnn::Mat, 6> infer(int eye, const ncnn::Mat& rgb);
    static std::array<ncnn::Mat, 4> own_states(const std::array<ncnn::Mat, 6>& outputs);
    const RvmProfile& profile_;
    const RvmPrecision precision_;
    // Destruction order: Net/pipelines before the GPU instance lease.
    std::shared_ptr<GpuLease> gpu_;
    ncnn::Net net_;
    std::array<std::array<ncnn::Mat, 4>, 2> states_;
    std::unique_ptr<ResidentGpuState> resident_;
    StateTransferStats transfers_;
};

#ifdef __ANDROID__
ncnn::Mat read_tensor(AAssetManager* assets, const char* path, TensorShape shape);
#endif
void check_tensor(const ncnn::Mat& tensor, TensorShape shape);
} // namespace quest
