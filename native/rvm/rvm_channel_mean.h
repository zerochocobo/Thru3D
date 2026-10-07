#pragma once
#include <net.h>

namespace quest {
// The pinned model has two channel means of FP32 RGB, keepdims=true.
// Replace only that exact Reduction form; reject any other model semantics.
void register_rvm_channel_mean(ncnn::Net& net);
}
