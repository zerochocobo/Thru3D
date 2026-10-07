#include "rvm_channel_mean.h"
#include <layer.h>
#include <pipeline.h>
#include <stdexcept>

namespace quest {
namespace {
// NCNN 20260526 Reduction dispatches one workgroup per output along Y.
// More than 65535 pixels exceeds common maxComputeWorkGroupCount[1].
// This RGB-specific mean dispatches 8x8 pixels per workgroup in two axes.
const char* shader = R"glsl(#version 450
layout(local_size_x=8, local_size_y=8, local_size_z=1) in;
layout(binding=0) readonly buffer Source { sfp src[]; };
layout(binding=1) writeonly buffer Target { sfp dst[]; };
layout(push_constant) uniform parameter { int width; int height; int cstep; } p;
void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    if (x >= uint(p.width) || y >= uint(p.height)) return;
    uint i = y*uint(p.width)+x;
    float mean = (float(buffer_ld1(src, i)) + float(buffer_ld1(src, i+uint(p.cstep))) +
                  float(buffer_ld1(src, i+2u*uint(p.cstep)))) / 3.0;
    buffer_st1(dst, i, mean);
}
)glsl";

class RvmChannelMean final : public ncnn::Layer {
public:
    RvmChannelMean() {
        one_blob_only = true;
        support_vulkan = true;
        support_fp16_storage = true;
        support_packing = false;
        support_vulkan_packing = false;
        support_vulkan_any_packing = false;
    }
    int load_param(const ncnn::ParamDict& params) override {
        const auto axes = params.get(3, ncnn::Mat());
        if (params.get(0, -1) != 3 || params.get(1, -1) != 0 ||
            axes.empty() || axes.dims != 1 || axes.w != 1 || static_cast<const int*>(axes.data)[0] != 0 ||
            params.get(2, 1.f) != 1.f || params.get(4, -1) != 1 || params.get(5, -1) != 1)
            return -1;
        return 0;
    }
    int create_pipeline(const ncnn::Option& opt) override {
        if (!opt.use_vulkan_compute) return 0;
        std::vector<uint32_t> spirv;
        if (ncnn::compile_spirv_module(shader, opt, spirv) != 0) return -1;
        pipeline = new ncnn::Pipeline(vkdev);
        pipeline->set_local_size_xyz(8, 8, 1);
        return pipeline->create(spirv.data(), spirv.size()*sizeof(uint32_t), {});
    }
    int destroy_pipeline(const ncnn::Option&) override {
        delete pipeline; pipeline = nullptr; return 0;
    }
    int forward(const ncnn::Mat& src, ncnn::Mat& dst, const ncnn::Option& opt) const override {
        if (src.dims != 3 || src.c != 3 || src.elempack != 1 || src.elemsize != 4) return -1;
        dst.create(src.w, src.h, 1, 4u, opt.blob_allocator);
        if (dst.empty()) return -100;
        const float* r = src.channel(0); const float* g = src.channel(1); const float* b = src.channel(2);
        float* target = dst.channel(0);
        for (int i = 0; i < src.w*src.h; ++i) target[i] = (r[i]+g[i]+b[i])/3.f;
        return 0;
    }
    int forward(const ncnn::VkMat& src, ncnn::VkMat& dst, ncnn::VkCompute& cmd, const ncnn::Option& opt) const override {
        const size_t scalar_bytes = opt.use_fp16_storage ? 2u : 4u;
        if (!pipeline || src.dims != 3 || src.c != 3 || src.elempack != 1 || src.elemsize != scalar_bytes) return -1;
        dst.create(src.w, src.h, 1, scalar_bytes, opt.blob_vkallocator);
        if (dst.empty()) return -100;
        std::vector<ncnn::vk_constant_type> constants(3);
        constants[0].i = src.w; constants[1].i = src.h; constants[2].i = static_cast<int>(src.cstep);
        cmd.record_pipeline(pipeline, std::vector<ncnn::VkMat>{src, dst}, constants, dst);
        return 0;
    }
private:
    ncnn::Pipeline* pipeline = nullptr;
};
ncnn::Layer* create(void*) { return new RvmChannelMean(); }
} // namespace

void register_rvm_channel_mean(ncnn::Net& net) {
    if (net.register_custom_layer("Reduction", create) != 0)
        throw std::runtime_error("RVM RGB channel mean registration failed");
}
} // namespace quest
