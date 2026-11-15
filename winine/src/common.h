// winine: a C++ implementation of ewv's native module (Edge WebView2 in Emacs
// windows, Direct3D 12 demos, Khronos Vulkan-Samples). See ../README.md.
//
// Shared by every source file: Windows headers, HRESULT checks, UTF-8 <->
// UTF-16 conversion and logging.
#pragma once

#ifndef NOMINMAX
#	define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#	define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <wrl.h>

#include <cstdint>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <string_view>

namespace winine
{
using Microsoft::WRL::ComPtr;

// A failed Windows call, with what was being done and the system's message.
class HResultError : public std::runtime_error
{
  public:
	HResultError(HRESULT hr, const std::string &what);
	HRESULT code;
};

inline void check(HRESULT hr, const char *what)
{
	if (FAILED(hr))
	{
		throw HResultError(hr, what);
	}
}

std::wstring widen(std::string_view utf8);
std::string  narrow(std::wstring_view utf16);
// Take ownership of a CoTaskMemAlloc'd string a WebView2 getter returned.
std::string take(LPWSTR s);

// stdout, like ewv's println! (visible when Emacs runs from a console).
void log(const char *format, ...);

// This DLL's module handle (window classes and hooks belong to it).
HINSTANCE dll_instance();
}        // namespace winine
