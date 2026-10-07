#include "rvm_identity_tile.h"
#include <layer.h>

namespace quest {
namespace {
class RvmIdentityTile final : public ncnn::Layer {
public:
    RvmIdentityTile() {
        one_blob_only = true;
        support_packing = true;
        support_fp16_storage = true;
        support_vulkan = true;
        support_vulkan_packing = true;
        support_vulkan_any_packing = true;
    }
    int load_param(const ncnn::ParamDict& params) override {
        const ncnn::Mat repeats = params.get(2, ncnn::Mat());
        if (params.get(0, 0) != 0 || params.get(1, 1) != 1 ||
            repeats.empty() || repeats.dims != 1 || repeats.w != 3) return -1;
        const int* values = repeats;
        return values[0] == 1 && values[1] == 1 && values[2] == 1 ? 0 : -1;
    }
    int forward(const ncnn::Mat& src, ncnn::Mat& dst, const ncnn::Option& opt) const override {
        if (!valid(src, opt)) return -1;
        dst = src;
        return 0;
    }
    int forward(const ncnn::VkMat& src, ncnn::VkMat& dst, ncnn::VkCompute&,
                const ncnn::Option& opt) const override {
        if (!valid(src, opt)) return -1;
        dst = src;
        return 0;
    }
private:
    template<class Tensor> static bool valid(const Tensor& src, const ncnn::Option& opt) {
        return !src.empty() && src.dims == 3 && src.w > 0 && src.h > 0 && src.c > 0 &&
            (src.elempack == 1 || src.elempack == 4 || src.elempack == 8) &&
            (src.elemsize == sizeof(float) * src.elempack ||
             (opt.use_fp16_storage && src.elemsize == size_t(2) * src.elempack));
    }
};
ncnn::Layer* create(void*) { return new RvmIdentityTile; }
}
void register_rvm_identity_tile(ncnn::Net& net) {
    net.register_custom_layer("Tile", create);
}
} // namespace quest
