#include "rvm_state_guard.h"
#include <stdexcept>

namespace quest {
namespace {
const char* shader = R"glsl(#version 450
layout(local_size_x=8, local_size_y=8, local_size_z=1) in;
layout(binding=0) readonly buffer Source { sfp src[]; };
layout(binding=1) buffer Target { uint flags[]; };
layout(push_constant) uniform parameter {
    int width; int height; int channels; int cstep; int pack; int state_index;
} p;
void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    uint q = gl_GlobalInvocationID.z;
    if (x >= uint(p.width) || y >= uint(p.height) || q >= uint(p.channels)) return;
    uint base = (q*uint(p.cstep)+y*uint(p.width)+x)*uint(p.pack);
    for (int lane=0; lane<p.pack; ++lane) {
        float v = float(buffer_ld1(src, base+uint(lane)));
        if (isnan(v) || isinf(v)) atomicOr(flags[p.state_index], 1u);
    }
}
)glsl";
}
StateFiniteGuard::StateFiniteGuard(const ncnn::VulkanDevice* device, const ncnn::Option& options)
    : pipeline_(device), scalar_bytes_(options.use_fp16_storage ? 2u : 4u) {
    std::vector<uint32_t> spirv;
    if (ncnn::compile_spirv_module(shader, options, spirv) != 0)
        throw std::runtime_error("RVM finite-state shader compilation failed");
    pipeline_.set_local_size_xyz(8, 8, 1);
    if (pipeline_.create(spirv.data(), spirv.size()*sizeof(uint32_t), {}) != 0)
        throw std::runtime_error("RVM finite-state pipeline creation failed");
}
StateFiniteGuard::~StateFiniteGuard() = default;
void StateFiniteGuard::record(ncnn::VkCompute& commands, const ncnn::VkMat& state,
                             ncnn::VkMat& flags, int index) const {
    if (index < 0 || index >= 8 || state.empty() || state.dims != 3 ||
        state.elemsize != scalar_bytes_*state.elempack || flags.empty() ||
        flags.dims != 1 || flags.w*flags.elempack != 8 || flags.elemsize != 4u*flags.elempack)
        throw std::runtime_error("RVM finite-state layout invalid");
    std::vector<ncnn::vk_constant_type> constants(6);
    constants[0].i = state.w; constants[1].i = state.h; constants[2].i = state.c;
    constants[3].i = static_cast<int>(state.cstep); constants[4].i = state.elempack; constants[5].i = index;
    commands.record_pipeline(&pipeline_, std::vector<ncnn::VkMat>{state, flags}, constants, state);
}
}
