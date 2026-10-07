// Diagnostic only: full GPU intermediate readbacks locate precision sensitivity.
// The CPU network is a numerical reference, not the player inference backend.
#include "rvm_backend.h"
#include "rvm_channel_mean.h"
#include "rvm_identity_tile.h"
#include <gpu.h>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <stdexcept>

static ncnn::Mat tensor(const std::string& path, quest::TensorShape shape) {
    std::ifstream file(path, std::ios::binary);
    if (!file) throw std::runtime_error("Missing input fixture");
    ncnn::Mat value(shape.width, shape.height, shape.channels);
    for (int c=0; c<shape.channels; ++c) {
        file.read(reinterpret_cast<char*>(static_cast<float*>(value.channel(c))), shape.width*shape.height*sizeof(float));
        if (!file) throw std::runtime_error("Truncated fixture");
    }
    if (file.peek() != std::ifstream::traits_type::eof()) throw std::runtime_error("Trailing fixture bytes");
    quest::check_tensor(value, shape);
    return value;
}

static void diagnose(char** argv) {
    const auto& profile=quest::find_profile(argv[4]);
    ncnn::Net reference, candidate;
    for (auto* net : {&reference, &candidate}) {
        net->opt.num_threads=4;
        net->opt.use_fp16_storage=net->opt.use_fp16_arithmetic=net->opt.use_fp16_packed=false;
        net->opt.use_bf16_storage=false;
    }
    candidate.opt.use_vulkan_compute=true; candidate.opt.use_fp16_storage=true;
    candidate.set_vulkan_device(0);
    if (!candidate.vulkan_device()->info.support_fp16_storage()) throw std::runtime_error("No Vulkan FP16 storage");
    quest::register_rvm_channel_mean(candidate); quest::register_rvm_identity_tile(candidate);
    for (auto* net : {&reference, &candidate})
        if (net->load_param(argv[1]) || net->load_model(argv[2])) throw std::runtime_error("Model loading failed");
    for (const auto* layer : candidate.layers()) if (!layer->support_vulkan) throw std::runtime_error("GPU partition incomplete");
    std::array<std::array<ncnn::Mat,4>,2> states;
    for (auto& eye : states) for (int s=0; s<4; ++s) {
        auto shape=profile.outputs[s+2]; eye[s].create(shape.width, shape.height, shape.channels); eye[s].fill(0.f);
    }
    std::cout << std::setprecision(12) << "{\"profile\":" << std::quoted(profile.key)
              << ",\"scope\":\"four left-eye frames; CPU FP32 versus GPU FP16 storage; diagnostic readbacks, no FPS claim\",\"rows\":[";
    bool first=true;
    for (int frame=0; frame<4; ++frame) {
        auto re=reference.create_extractor(), ce=candidate.create_extractor();
        re.set_light_mode(false); ce.set_light_mode(false);
        const auto input=tensor(std::string(argv[3])+"/left_"+std::to_string(frame)+".src.f32", profile.rgb);
        if (re.input("in0", input) || ce.input("in0", input)) throw std::runtime_error("RGB input failed");
        for (int s=0; s<4; ++s) {
            const auto name="in"+std::to_string(s+1);
            if (re.input(name.c_str(), states[0][s]) || ce.input(name.c_str(), states[1][s])) throw std::runtime_error("State input failed");
        }
        for (size_t index=0; index<reference.blobs().size(); ++index) {
            const auto& blob=reference.blobs()[index];
            ncnn::Mat a,b;
            if (re.extract(blob.name.c_str(),a) || ce.extract(blob.name.c_str(),b)) throw std::runtime_error("Intermediate extraction failed");
            if (a.empty() || b.empty() || a.dims!=b.dims || a.w!=b.w || a.h!=b.h || a.c!=b.c ||
                a.elempack!=1 || b.elempack!=1 || a.elemsize!=4 || b.elemsize!=4 || a.dims>3)
                throw std::runtime_error("Intermediate host layout differs");
            double max_abs=0, squared=0, magnitude=0;
            size_t above=0;
            for (int c=0; c<a.c; ++c) {
                const float* av=a.channel(c); const float* bv=b.channel(c);
                for (int i=0; i<a.w*a.h; ++i) {
                    if (!std::isfinite(av[i]) || !std::isfinite(bv[i])) throw std::runtime_error("Nonfinite intermediate");
                    const double delta=std::abs(double(av[i])-bv[i]);
                    max_abs=std::max(max_abs,delta); squared+=delta*delta;
                    magnitude=std::max(magnitude,std::abs(double(av[i]))); above+=delta>.005;
                }
            }
            if (!first) std::cout << ','; first=false;
            const auto* producer=reference.layers().at(blob.producer);
            std::cout << "{\"frame\":" << frame << ",\"index\":" << index << ",\"blob\":" << std::quoted(blob.name)
                << ",\"layer\":" << std::quoted(producer->name) << ",\"type\":" << std::quoted(producer->type)
                << ",\"max_abs\":" << max_abs << ",\"rms\":" << std::sqrt(squared/(double(a.w)*a.h*a.c))
                << ",\"reference_magnitude\":" << magnitude << ",\"pixels_above_005\":" << above << '}';
        }
        for (int s=0; s<4; ++s) {
            const auto name="out"+std::to_string(s+2);
            if (re.extract(name.c_str(),states[0][s]) || ce.extract(name.c_str(),states[1][s])) throw std::runtime_error("State output failed");
            quest::check_tensor(states[0][s],profile.outputs[s+2]); quest::check_tensor(states[1][s],profile.outputs[s+2]);
        }
    }
    std::cout << "]}" << std::endl;
}

int main(int argc, char** argv) {
    if (argc!=5) { std::cerr << "param bin fixture-directory profile"; return 2; }
    if (ncnn::create_gpu_instance()!=0) return 2;
    int code=0;
    try { diagnose(argv); }
    catch (const std::exception& error) { std::cerr << error.what() << std::endl; code=2; }
    ncnn::destroy_gpu_instance();
    return code;
}
