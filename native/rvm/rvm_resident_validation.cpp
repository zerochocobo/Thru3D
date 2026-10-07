#include "rvm_resident_validation.h"
#include "rvm_state_guard.h"
#include "rvm_identity_tile.h"
#include <layer.h>
#include <gpu.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <sstream>
#include <iomanip>
#include <stdexcept>

static void verify_identity_tile(bool half) {
    ncnn::Net net;
    quest::register_rvm_identity_tile(net);
    if (net.load_param_mem("7767517\n2 2\nInput source 0 1 src\nTile identity 1 1 src dst -23302=3,1,1,1\n"))
        throw std::runtime_error("Identity Tile load failed");
    auto* layer = net.layers().at(1);
    if (!layer->support_vulkan || !layer->support_vulkan_any_packing || layer->support_inplace)
        throw std::runtime_error("Identity Tile dispatch contract differs");
    const auto* device = ncnn::get_gpu_device(0);
    auto* blob = device->acquire_blob_allocator();
    auto* staging = device->acquire_staging_allocator();
    if (!blob || !staging) throw std::runtime_error("Identity oracle allocator unavailable");
    try {
        ncnn::Option opt;
        opt.use_fp16_packed = opt.use_fp16_storage = opt.use_fp16_arithmetic = false;
        opt.use_fp16_storage = half;
        opt.blob_vkallocator = opt.workspace_vkallocator = blob;
        opt.staging_vkallocator = staging;
        for (int pack : {1, 4, 8}) {
            ncnn::Mat src(2, 3, 2, sizeof(float)*pack, pack), dst;
            src.fill(0.625f);
            if (layer->forward(src, dst, opt) || dst.data != src.data || dst.elempack != pack)
                throw std::runtime_error("CPU identity Tile altered its tensor");
            ncnn::VkCompute commands(device);
            ncnn::VkMat input, output;
            opt.use_packing_layout = pack != 1;
            commands.record_upload(src, input, opt);
            ncnn::VkMat packed_input;
            device->convert_packing(input, packed_input, pack == 8 ? 4 : pack, half ? 2 : 1, commands, opt);
            input = packed_input;
            if (layer->forward(input, output, commands, opt) || input.data != output.data ||
                input.elempack != output.elempack || input.cstep != output.cstep ||
                input.elemsize != (half ? size_t(2) : sizeof(float))*input.elempack)
                throw std::runtime_error("Vulkan identity Tile copied or altered its tensor");
            if (commands.submit_and_wait()) throw std::runtime_error("Identity oracle upload failed");
        }
        ncnn::Mat dst;
        if (!layer->forward(ncnn::Mat(2, 3), dst, opt) ||
            !layer->forward(ncnn::Mat(2, 3, 2, half ? size_t(1) : size_t(2), 1), dst, opt))
            throw std::runtime_error("Identity Tile accepted a wrong rank or precision");
        for (int test = 0; test < 6; ++test) {
            ncnn::ParamDict invalid;
            if (test != 0) {
                ncnn::Mat repeats(test == 2 ? 2 : test == 3 ? 4 : 3);
                int* values = static_cast<int*>(repeats.data);
                for (int i = 0; i < repeats.w; ++i) values[i] = test == 1 && i == 1 ? 2 : 1;
                invalid.set(2, repeats);
            }
            if (test == 4) invalid.set(0, 1);
            if (test == 5) invalid.set(1, 2);
            if (!layer->load_param(invalid))
                throw std::runtime_error("Identity Tile accepted unsupported repeat semantics");
        }
    } catch (...) {
        device->reclaim_staging_allocator(staging); device->reclaim_blob_allocator(blob); throw;
    }
    device->reclaim_staging_allocator(staging); device->reclaim_blob_allocator(blob);
}

static void verify_finite_guard(bool half) {
    const auto* device = ncnn::get_gpu_device(0);
    auto* blob = device->acquire_blob_allocator();
    auto* staging = device->acquire_staging_allocator();
    if (!blob || !staging) throw std::runtime_error("Guard oracle allocator unavailable");
    try {
        ncnn::Option options;
        options.use_fp16_packed = options.use_fp16_storage = options.use_fp16_arithmetic = false;
        options.use_fp16_storage = half;
        options.blob_vkallocator = options.workspace_vkallocator = blob;
        options.staging_vkallocator = staging;
        quest::StateFiniteGuard guard(device, options);
        auto flag_options = options;
        flag_options.use_fp16_storage = false;
        flag_options.use_packing_layout = false;
        for (bool packed : {false, true}) {
            ncnn::VkCompute commands(device);
            ncnn::Mat zeros(8), checked; zeros.fill(0.f);
            ncnn::VkMat flags;
            options.use_packing_layout = false;
            commands.record_upload(zeros, flags, flag_options);
            std::array<ncnn::VkMat, 8> states;
            std::array<ncnn::Mat, 8> sources;
            for (int index = 0; index < 8; ++index) {
                auto& src = sources[index]; src.create(2, 3, 4); src.fill(1.f);
                float* tail = src.channel(3);
                if (index == 1) tail[5] = NAN;
                if (index == 2) tail[5] = INFINITY;
                if (index == 3) tail[5] = -INFINITY;
                options.use_packing_layout = packed;
                commands.record_upload(src, states[index], options);
                ncnn::VkMat packed_state;
                device->convert_packing(states[index], packed_state, packed ? 4 : 1, half ? 2 : 1, commands, options);
                states[index] = packed_state;
                if (states[index].elempack != (packed ? 4 : 1))
                    throw std::runtime_error("Guard oracle did not exercise requested packing");
                guard.record(commands, states[index], flags, index);
            }
            options.use_packing_layout = false;
            commands.record_download(flags, checked, flag_options);
            if (commands.submit_and_wait() != 0 || checked.empty() || checked.w != 8 || checked.elempack != 1)
                throw std::runtime_error("Guard oracle submission failed");
            const auto* values = static_cast<const uint32_t*>(checked.data);
            for (int index = 0; index < 8; ++index)
                if (values[index] != ((index >= 1 && index <= 3) ? 1u : 0u))
                    throw std::runtime_error("Guard oracle missed nonfinite state or corrupted another eye flag");
        }
    } catch (...) {
        device->reclaim_staging_allocator(staging); device->reclaim_blob_allocator(blob); throw;
    }
    device->reclaim_staging_allocator(staging); device->reclaim_blob_allocator(blob);
}

static double difference(const ncnn::Mat& a, const ncnn::Mat& b) {
    double result = 0;
    for (int c = 0; c < a.c; ++c) {
        const float* av = a.channel(c); const float* bv = b.channel(c);
        for (int i = 0; i < a.w*a.h; ++i) result = std::max(result, std::abs(double(av[i])-bv[i]));
    }
    return result;
}

static double rms_difference(const ncnn::Mat& a, const ncnn::Mat& b) {
    double sum = 0;
    for (int c = 0; c < a.c; ++c) {
        const float* av = a.channel(c); const float* bv = b.channel(c);
        for (int i = 0; i < a.w*a.h; ++i) {
            const double delta = double(av[i])-bv[i]; sum += delta*delta;
        }
    }
    return std::sqrt(sum / (double(a.w)*a.h*a.c));
}


std::string quest::validate_resident(RvmBackend& backend, const ResidentFixtureReader& read) {
    if (!backend.uses_vulkan()) throw std::runtime_error("Resident validation requires Vulkan");
    const auto& profile = backend.profile();
    std::ostringstream json;
    json << std::setprecision(12);
        const auto& device = ncnn::get_gpu_info(0);
        const bool half = backend.uses_half_storage();
        verify_finite_guard(half);
        verify_identity_tile(half);
        std::array<std::array<ncnn::Mat, 4>, 2> inputs;
        std::array<std::array<ncnn::Mat, 4>, 2> reference_alpha;
        std::array<std::array<std::array<ncnn::Mat, 4>, 4>, 2> reference_states;
        const char* state_names[] = {"r1o", "r2o", "r3o", "r4o"};
        for (int eye = 0; eye < 2; ++eye) for (int frame = 0; frame < 4; ++frame) {
            const auto prefix = std::string()+(eye ? "right_" : "left_")+std::to_string(frame);
            inputs[eye][frame] = read(prefix+".src.f32", profile.rgb);
            reference_alpha[eye][frame] = read(prefix+".pha.f32", profile.outputs[1]);
            for (int s = 0; s < 4; ++s)
                reference_states[eye][frame][s] = read(prefix+"."+state_names[s]+".f32", profile.outputs[s+2]);
        }
        double mask_error = 0, state_error = 0, mask_rms = 0, state_rms = 0;
        std::array<double, 4> times;
        std::array<ResidentPhaseTiming, 4> phase_times;
        std::array<ncnn::Mat, 2> first;
        for (int frame = 0; frame < 4; ++frame) {
            const auto start = std::chrono::steady_clock::now();
            const auto alpha = backend.process_alpha_stereo({{inputs[0][frame], inputs[1][frame]}}, &phase_times[frame]);
            times[frame] = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now()-start).count();
            if (frame == 0) first = alpha;
            const auto states = backend.snapshot_resident_states();
            for (int eye = 0; eye < 2; ++eye) {
                mask_error = std::max(mask_error, difference(alpha[eye], reference_alpha[eye][frame]));
                mask_rms = std::max(mask_rms, rms_difference(alpha[eye], reference_alpha[eye][frame]));
                for (int s = 0; s < 4; ++s) {
                    state_error = std::max(state_error, difference(states[eye][s], reference_states[eye][frame][s]));
                    state_rms = std::max(state_rms, rms_difference(states[eye][s], reference_states[eye][frame][s]));
                }
            }
        }
        backend.reset(0); backend.reset(1);
        bool rejected = false;
        try { backend.process_alpha_stereo({{inputs[0][0], ncnn::Mat()}}); }
        catch (const std::exception&) { rejected = true; }
        if (!rejected) throw std::runtime_error("Invalid right input accepted");
        const auto retry = backend.process_alpha_stereo({{inputs[0][0], inputs[1][0]}});
        double reset_error = std::max(difference(retry[0], first[0]), difference(retry[1], first[1]));
        const auto before = backend.snapshot_resident_states();
        const auto commits_before = backend.transfer_stats().committed_stereo_frames;
        bool nonfinite_rejected = false;
        auto bad_right = inputs[1][1].clone();
        static_cast<float*>(bad_right.channel(0))[0] = NAN;
        try { backend.process_alpha_stereo({{inputs[0][1], bad_right}}); }
        catch (const std::exception&) { nonfinite_rejected = true; }
        if (!nonfinite_rejected || backend.transfer_stats().committed_stereo_frames != commits_before)
            throw std::runtime_error("Invalid right input advanced resident recurrence");
        const auto after = backend.snapshot_resident_states();
        double rejected_state_error = 0;
        for (int eye = 0; eye < 2; ++eye) for (int s = 0; s < 4; ++s)
            rejected_state_error = std::max(rejected_state_error, difference(before[eye][s], after[eye][s]));
        // Resetting left must not reset right; compare its continued recurrence
        // with the independently computed second right frame.
        backend.reset(0);
        const auto isolated = backend.process_alpha_stereo({{inputs[0][0], inputs[1][1]}});
        const double isolation_error = std::max(difference(isolated[0], first[0]), difference(isolated[1], reference_alpha[1][1]));
        const auto& stats = backend.transfer_stats();
        const auto isolated_states = backend.snapshot_resident_states();
        for (int eye = 0; eye < 2; ++eye) for (int s = 0; s < 4; ++s) {
            const auto& expected = reference_states[eye][eye ? 1 : 0][s];
            state_error = std::max(state_error, difference(isolated_states[eye][s], expected));
            state_rms = std::max(state_rms, rms_difference(isolated_states[eye][s], expected));
        }
        // Separate, predeclared storage-only diagnostic policy. FP32 gates stay unchanged.
        const double mask_bound = half ? .005 : 1e-4;
        const double state_bound = half ? .05 : 1e-3;
        const double mask_rms_bound = half ? .001 : 1e-4;
        const double state_rms_bound = half ? .005 : 1e-4;
        const bool passed = mask_error <= mask_bound && state_error <= state_bound && mask_rms <= mask_rms_bound && state_rms <= state_rms_bound
                         && reset_error <= 1e-6 && rejected_state_error == 0 && isolation_error <= mask_bound;
        json << "{\"state\":\"" << (passed ? "passed" : "failed") << "\",\"profile\":\"" << profile.key
                  << "\",\"alpha_max_abs\":" << mask_error << ",\"recurrent_max_abs\":" << state_error
                  << ",\"alpha_max_rms\":" << mask_rms << ",\"recurrent_max_rms\":" << state_rms
                  << ",\"reset_rollback_max_abs\":" << reset_error << ",\"isolation_max_abs\":" << isolation_error
                  << ",\"rejected_state_max_abs\":" << rejected_state_error
                  << ",\"invalid_right_rejected\":true,\"nonfinite_right_rejected\":true,\"committed_stereo_frames\":" << stats.committed_stereo_frames
                  << ",\"rgb_upload_bytes\":" << stats.rgb_upload_bytes << ",\"initial_state_upload_bytes\":" << stats.initial_state_upload_bytes
                  << ",\"alpha_download_bytes\":" << stats.alpha_download_bytes
                  << ",\"validation_upload_bytes\":" << stats.validation_upload_bytes
                  << ",\"validation_download_bytes\":" << stats.validation_download_bytes
                  << ",\"gpu_finite_guard_verified\":true"
                  << ",\"diagnostic_state_download_bytes\":" << stats.diagnostic_state_download_bytes
                  << ",\"state_storage\":\"" << (half ? "VkMat_FP16" : "VkMat_FP32")
                  << "\",\"precision\":\"" << (half ? "fp16_storage_fp32_arithmetic" : "fp32")
                  << "\",\"numeric_policy\":\"" << (half ? "R04_STORAGE_V1" : "R01_FP32")
                  << "\",\"gpu_state_scalar_bytes\":" << (half ? 2 : 4)
                  << ",\"host_io_scalar_bytes\":4,\"fp16_arithmetic\":false,\"finite_flags_scalar_bytes\":4"
                  << ",\"fp16_storage_supported\":" << (device.support_fp16_storage() ? "true" : "false")
                  << ",\"alpha_max_abs_limit\":" << mask_bound << ",\"recurrent_max_abs_limit\":" << state_bound
                  << ",\"alpha_max_rms_limit\":" << mask_rms_bound << ",\"recurrent_max_rms_limit\":" << state_rms_bound
                  << ",\"transfer_count_scope\":\"Logical FP32 host input/output bytes; excludes internal casts, padding and driver traffic\""
                  << ",\"production_explicit_recurrent_download_bytes\":0,\"vulkan_capable_layers\":"
                  << backend.vulkan_capable_layers() << ",\"layer_count\":" << backend.layer_count()
                  << ",\"identity_tile_contract_verified\":true,\"non_vulkan_layers\":[";
        bool first_layer = true;
        for (const auto& name : backend.non_vulkan_layers()) {
            if (!first_layer) json << ',';
            first_layer = false;
            json << '"' << name << '"';
        }
        json << ']'
                  << ",\"max_workgroup_count_y\":" << device.max_workgroup_count_y()
                  << ",\"scope\":\"Same production resident backend, independent four-frame ONNX oracle; full state readback is diagnostic; video/quality/thermal/internal fallback traffic unverified\",\"stereo_ms\":[";
        for (int i = 0; i < 4; ++i) { if (i) json << ','; json << times[i]; }
        json << "],\"phase_timing_scope\":\"CPU steady-clock wall phases; submit_wait includes GPU and queue/transfers; diagnostic snapshots excluded\",\"phase_ms\":[";
        const char* phase_names[] = {"input_validation", "setup", "command_record", "submit_wait",
                                     "output_validation", "commit", "teardown"};
        for (int frame = 0; frame < 4; ++frame) {
            if (frame) json << ',';
            json << "{\"completed\":" << (phase_times[frame].completed ? "true" : "false")
                 << ",\"total\":" << phase_times[frame].total_ms;
            for (int phase = 0; phase < 7; ++phase)
                json << ",\"" << phase_names[phase] << "\":" << phase_times[frame].phases_ms[phase];
            json << '}';
        }
        json << "]}";
    return json.str();
}
