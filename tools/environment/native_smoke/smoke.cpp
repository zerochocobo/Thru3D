#include <net.h>
#include <gpu.h>

// Link validation only. No RVM model or device execution is involved.
extern "C" __attribute__((visibility("default"))) int quest_ncnn_smoke() {
    ncnn::Net net;
    net.opt.use_vulkan_compute = true;
    const ncnn::Mat input(2, 2, 3);
    return ncnn::get_gpu_count() + input.c;
}

