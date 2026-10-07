#include "rvm_resident_validation.h"
#include <gpu.h>
#include "rvm_state_guard.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <fstream>
#include <iostream>
#include <sstream>

static void compare_layers(const char* param, const char* bin, const std::array<ncnn::Mat, 2>& src,
                           const quest::RvmProfile& profile) {
    ncnn::Net cpu, gpu;
    for (auto* net : {&cpu, &gpu}) {
        net->opt.num_threads = 4;
        net->opt.use_fp16_packed = net->opt.use_fp16_storage = net->opt.use_fp16_arithmetic = false;
        net->opt.use_bf16_storage = false;
    }
    gpu.opt.use_vulkan_compute = true; gpu.set_vulkan_device(0);
    for (auto* net : {&cpu, &gpu})
        if (net->load_param(param) || net->load_model(bin)) throw std::runtime_error("Layer diagnostic model load failed");
    auto ce = cpu.create_extractor(), ge = gpu.create_extractor();
    ce.set_light_mode(false); ge.set_light_mode(false);
    ce.input("in0", src[0]); ge.input("in0", src[0]);
    for (int i = 0; i < 4; ++i) {
        auto shape = profile.outputs[i+2]; ncnn::Mat zero(shape.width, shape.height, shape.channels); zero.fill(0.f);
        const auto name = "in"+std::to_string(i+1); ce.input(name.c_str(), zero); ge.input(name.c_str(), zero);
    }
    for (const auto& blob : cpu.blobs()) {
        ncnn::Mat a, b;
        if (ce.extract(blob.name.c_str(), a) || ge.extract(blob.name.c_str(), b)) throw std::runtime_error("Layer diagnostic extraction failed");
        if (a.dims != b.dims || a.w != b.w || a.h != b.h || a.c != b.c || a.elempack != 1 || b.elempack != 1)
            throw std::runtime_error("Layer diagnostic layout differs");
        double error = 0;
        for (int c = 0; c < a.c; ++c) {
            const float* av = a.channel(c); const float* bv = b.channel(c);
            for (int i = 0; i < a.w*a.h; ++i) error = std::max(error, std::abs(double(av[i])-bv[i]));
        }
        if (error > 1e-3) std::cerr << "blob=" << blob.name << " error=" << error << " shape=" << a.w << ',' << a.h << ',' << a.c << '\n';
    }
}

static ncnn::Mat tensor(const std::string& path, quest::TensorShape shape) {
    std::ifstream file(path, std::ios::binary);
    if (!file) throw std::runtime_error("Oracle file missing: " + path);
    ncnn::Mat value(shape.width, shape.height, shape.channels);
    for (int c = 0; c < shape.channels; ++c) {
        file.read(reinterpret_cast<char*>(static_cast<float*>(value.channel(c))), shape.width*shape.height*sizeof(float));
        if (!file) throw std::runtime_error("Oracle file truncated: " + path);
    }
    if (file.peek() != std::ifstream::traits_type::eof()) throw std::runtime_error("Oracle trailing data");
    quest::check_tensor(value, shape);
    return value;
}

int main(int argc, char** argv) {
    try {
        if (argc != 5 && argc != 6) throw std::runtime_error("Usage: param bin fixture-directory profile-key [--layers]");
        const auto& profile = quest::find_profile(argv[4]);
        const bool half = argc == 6 && std::string(argv[5]) == "--half-storage";
        quest::RvmBackend backend(argv[1], argv[2], true, profile,
            half ? quest::RvmPrecision::FP16Storage : quest::RvmPrecision::FP32);
        if (argc == 6 && !half) {
            if (std::string(argv[5]) == "--partition") {
                std::cout << "{\"unsupported\":[";
                bool first = true;
                for (const auto& name : backend.non_vulkan_layers()) {
                    if (!first) std::cout << ',';
                    first = false;
                    std::cout << '\"' << name << '\"';
                }
                std::cout << "]}" << std::endl;
                return 0;
            }
            if (std::string(argv[5]) != "--layers") throw std::runtime_error("Unknown diagnostic option");
            compare_layers(argv[1], argv[2], {{tensor(std::string(argv[3])+"/left_0.src.f32", profile.rgb),
                tensor(std::string(argv[3])+"/right_0.src.f32", profile.rgb)}}, profile);
            return 0;
        }
        const auto result = quest::validate_resident(backend, [&](const std::string& file, quest::TensorShape shape) {
            return tensor(std::string(argv[3])+"/"+file, shape);
        });
        std::cout << result << std::endl;
        return result.find("\"state\":\"passed\"") != std::string::npos ? 0 : 1;
    } catch (const std::exception& failure) {
        std::cerr << failure.what() << std::endl; return 2;
    }
}
