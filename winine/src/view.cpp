#include "view.h"

#include <algorithm>
#include <mutex>
#include <set>
#include <string>

namespace winine
{
int64_t new_view_id()
{
	static std::atomic<int64_t> next{1};
	return next++;
}

HWND create_view_window(const wchar_t *class_name, WNDPROC procedure, HWND parent, bool disabled)
{
	static std::mutex              mutex;
	static std::set<std::wstring>  registered;
	HINSTANCE                      instance = dll_instance();
	{
		std::lock_guard<std::mutex> lock(mutex);
		if (registered.insert(class_name).second)
		{
			WNDCLASSW wc{};
			wc.lpfnWndProc   = procedure;
			wc.hInstance     = instance;
			wc.lpszClassName = class_name;
			wc.hCursor       = LoadCursorW(nullptr, IDC_ARROW);
			RegisterClassW(&wc);
		}
	}
	DWORD style = WS_CHILD | WS_CLIPSIBLINGS | (disabled ? WS_DISABLED : 0);
	HWND  hwnd  = CreateWindowExW(WS_EX_NOPARENTNOTIFY, class_name, class_name, style, 0, 0, 1, 1, parent, nullptr,
	                              instance, nullptr);
	if (!hwnd)
	{
		check(HRESULT_FROM_WIN32(GetLastError()), "CreateWindowExW");
	}
	return hwnd;
}

bool apply_command(HWND hwnd, Command &command, std::pair<uint32_t, uint32_t> &size, bool &visible)
{
	switch (command.kind)
	{
		case Command::Bounds:
		{
			const RECT &r = command.bounds;
			int         w = std::max<LONG>(r.right - r.left, 1);
			int         h = std::max<LONG>(r.bottom - r.top, 1);
			size          = {static_cast<uint32_t>(w), static_cast<uint32_t>(h)};
			SetWindowPos(hwnd, HWND_TOP, r.left, r.top, w, h, SWP_NOACTIVATE);
			return true;
		}
		case Command::Visible:
			visible = command.visible;
			ShowWindow(hwnd, visible ? SW_SHOWNA : SW_HIDE);
			return true;
		case Command::Parent:
			SetParent(hwnd, command.parent);
			if (command.done)
			{
				command.done->set_value();
			}
			return true;
		case Command::Close:
		default:
			return false;
	}
}

bool pump_view_messages()
{
	MSG msg;
	while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE))
	{
		if (msg.message == WM_QUIT)
		{
			return false;
		}
		DispatchMessageW(&msg);
	}
	return true;
}
}        // namespace winine
