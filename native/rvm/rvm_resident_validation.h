#pragma once
#include "rvm_backend.h"
#include <functional>
namespace quest {
using ResidentFixtureReader = std::function<ncnn::Mat(const std::string&, TensorShape)>;
// Diagnostic only: downloads all states to compare independent reference outputs.
std::string validate_resident(RvmBackend& backend, const ResidentFixtureReader& read);
}
