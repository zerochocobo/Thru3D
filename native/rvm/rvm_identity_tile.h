#pragma once
#include <net.h>

namespace quest {
// Four fixed-profile Tile nodes repeat a 3D state by [1,1,1].
// Keep that exact identity on the GPU instead of ncnn's CPU Tile fallback.
void register_rvm_identity_tile(ncnn::Net& net);
}
