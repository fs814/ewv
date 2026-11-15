// Microsoft DirectX-Graphics-Samples views: the C++ counterpart of ewv's
// src/dxs.rs. Each sample stays the Win32 program upstream wrote (built by
// ewv's src/dxsamples/build.ps1); a view starts it hidden, adopts its window
// as a borderless child of the Emacs frame, and places / shows / moves it on
// Lisp's commands. The sample keeps its own process and keyboard input.
#pragma once

#include "view.h"

#include <memory>
#include <string>

namespace winine::dxs
{
// Start EXE with ARGS (a command line tail) in CWD; embed its window in PARENT.
std::unique_ptr<ViewHandle> open(const std::string &exe, const std::string &args, const std::string &cwd, HWND parent);
}        // namespace winine::dxs
