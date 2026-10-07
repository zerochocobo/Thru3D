// Generated from verified ONNX/ncnn shapes; do not edit.
#pragma once
namespace quest {
inline constexpr std::array<RvmProfile, 7> kRvmProfiles{{
    {"256x144", "256x144_ratio1_fp32", "rvm/256x144/rvm.ncnn.param", "rvm/256x144/rvm.ncnn.bin", "rvm/reference/", {256, 144, 3}, {{{256, 144, 3}, {256, 144, 1}, {128, 72, 16}, {64, 36, 20}, {32, 18, 40}, {16, 9, 64}}}},
    {"384x216", "384x216_ratio1_fp32", "rvm/384x216/rvm.ncnn.param", "rvm/256x144/rvm.ncnn.bin", "rvm/reference/384x216/", {384, 216, 3}, {{{384, 216, 3}, {384, 216, 1}, {192, 108, 16}, {96, 54, 20}, {48, 27, 40}, {24, 14, 64}}}},
    {"512x288", "512x288_ratio1_fp32", "rvm/256x144/rvm.ncnn.param", "rvm/256x144/rvm.ncnn.bin", "rvm/reference/512x288/", {512, 288, 3}, {{{512, 288, 3}, {512, 288, 1}, {256, 144, 16}, {128, 72, 20}, {64, 36, 40}, {32, 18, 64}}}},
    {"256x256", "256x256_ratio1_fp32", "rvm/256x144/rvm.ncnn.param", "rvm/256x144/rvm.ncnn.bin", "rvm/reference/256x256/", {256, 256, 3}, {{{256, 256, 3}, {256, 256, 1}, {128, 128, 16}, {64, 64, 20}, {32, 32, 40}, {16, 16, 64}}}},
    {"384x384", "384x384_ratio1_fp32", "rvm/256x144/rvm.ncnn.param", "rvm/256x144/rvm.ncnn.bin", "rvm/reference/384x384/", {384, 384, 3}, {{{384, 384, 3}, {384, 384, 1}, {192, 192, 16}, {96, 96, 20}, {48, 48, 40}, {24, 24, 64}}}},
    {"512x512", "512x512_ratio1_fp32", "rvm/256x144/rvm.ncnn.param", "rvm/256x144/rvm.ncnn.bin", "rvm/reference/512x512/", {512, 512, 3}, {{{512, 512, 3}, {512, 512, 1}, {256, 256, 16}, {128, 128, 20}, {64, 64, 40}, {32, 32, 64}}}},
    {"320x320", "320x320_ratio1_fp32", "rvm/256x144/rvm.ncnn.param", "rvm/256x144/rvm.ncnn.bin", "rvm/reference/320x320/", {320, 320, 3}, {{{320, 320, 3}, {320, 320, 1}, {160, 160, 16}, {80, 80, 20}, {40, 40, 40}, {20, 20, 64}}}},
}};
} // namespace quest
