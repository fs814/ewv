#include "common.h"

#include <cstdarg>

namespace winine
{
static std::string describe(HRESULT hr, const std::string &what)
{
	char  buffer[64];
	LPSTR text = nullptr;
	FormatMessageA(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
	               nullptr, static_cast<DWORD>(hr), 0, reinterpret_cast<LPSTR>(&text), 0, nullptr);
	std::snprintf(buffer, sizeof buffer, " (0x%08lX)", static_cast<unsigned long>(hr));
	std::string message = what + ": " + (text ? std::string(text) : std::string("error")) + buffer;
	if (text)
	{
		LocalFree(text);
	}
	// FormatMessage ends its text with CR LF.
	for (auto pos = message.find("\r\n"); pos != std::string::npos; pos = message.find("\r\n"))
	{
		message.erase(pos, 2);
	}
	return message;
}

HResultError::HResultError(HRESULT hr, const std::string &what) :
    std::runtime_error(describe(hr, what)), code(hr)
{}

std::wstring widen(std::string_view utf8)
{
	if (utf8.empty())
	{
		return {};
	}
	int          n = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
	std::wstring out(n, L'\0');
	MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), out.data(), n);
	return out;
}

std::string narrow(std::wstring_view utf16)
{
	if (utf16.empty())
	{
		return {};
	}
	int n = WideCharToMultiByte(CP_UTF8, 0, utf16.data(), static_cast<int>(utf16.size()), nullptr, 0, nullptr, nullptr);
	std::string out(n, '\0');
	WideCharToMultiByte(CP_UTF8, 0, utf16.data(), static_cast<int>(utf16.size()), out.data(), n, nullptr, nullptr);
	return out;
}

std::string take(LPWSTR s)
{
	if (!s)
	{
		return {};
	}
	std::string out = narrow(s);
	CoTaskMemFree(s);
	return out;
}

void log(const char *format, ...)
{
	va_list args;
	va_start(args, format);
	std::vfprintf(stdout, format, args);
	va_end(args);
	std::fputc('\n', stdout);
	std::fflush(stdout);
}

HINSTANCE dll_instance()
{
	HMODULE module = nullptr;
	GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
	                   reinterpret_cast<LPCWSTR>(&dll_instance), &module);
	return module;
}
}        // namespace winine
