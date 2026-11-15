// Khronos Vulkan-Samples views: the C++ counterpart of ewv's src/vks.rs. The
// samples are ewv's separate library, ewv-vulkan-samples.dll (ewv's
// src/vulkan/build.ps1), loaded on first use; winine shares it with ewv.
#pragma once

#include "view.h"

#include <memory>
#include <string>

namespace winine::vks
{
// Open SAMPLE (e.g. "hello_triangle") from LIBRARY (ewv-vulkan-samples.dll)
// with ROOT (the Vulkan-Samples folder holding assets\ and shaders\) as a
// hidden child window of PARENT. The sample starts when first shown with a size.
std::unique_ptr<ViewHandle> open(const std::string &sample, HWND parent, const std::string &library,
                                 const std::string &root);
}        // namespace winine::vks
