#pragma once
#include <command.h>
#include <pipeline.h>

namespace quest {
class StateFiniteGuard final {
public:
    StateFiniteGuard(const ncnn::VulkanDevice* device, const ncnn::Option& options);
    ~StateFiniteGuard();
    StateFiniteGuard(const StateFiniteGuard&) = delete;
    StateFiniteGuard& operator=(const StateFiniteGuard&) = delete;
    void record(ncnn::VkCompute& commands, const ncnn::VkMat& state,
                ncnn::VkMat& eight_flags, int state_index) const;
private:
    ncnn::Pipeline pipeline_;
    size_t scalar_bytes_;
};
}
