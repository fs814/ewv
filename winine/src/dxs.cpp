#include "dxs.h"

#include <chrono>
#include <thread>

namespace winine::dxs
{
namespace
{
// A top-level window of process PID with a caption and no owner: the
// sample's main window (not an IME or other helper window).
HWND find_main_window(DWORD pid)
{
	struct Search
	{
		DWORD pid;
		HWND  found;
	} search{pid, nullptr};
	EnumWindows(
	    [](HWND hwnd, LPARAM lparam) -> BOOL {
		    auto *s     = reinterpret_cast<Search *>(lparam);
		    DWORD owner = 0;
		    GetWindowThreadProcessId(hwnd, &owner);
		    LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_STYLE);
		    if (owner == s->pid && (style & WS_CAPTION) == WS_CAPTION && !GetWindow(hwnd, GW_OWNER))
		    {
			    s->found = hwnd;
			    return FALSE;
		    }
		    return TRUE;
	    },
	    reinterpret_cast<LPARAM>(&search));
	return search.found;
}

// Turn the sample's top-level window into a borderless child of PARENT.
void adopt(HWND hwnd, HWND parent)
{
	LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_STYLE);
	style &= ~static_cast<LONG_PTR>(WS_POPUP | WS_CAPTION | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX);
	SetWindowLongPtrW(hwnd, GWL_STYLE, style | WS_CHILD | WS_CLIPSIBLINGS);
	LONG_PTR ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
	ex &= ~static_cast<LONG_PTR>(WS_EX_APPWINDOW | WS_EX_WINDOWEDGE | WS_EX_CLIENTEDGE | WS_EX_DLGMODALFRAME);
	SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex);
	SetParent(hwnd, parent);
	SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
	             SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_ASYNCWINDOWPOS);
}

// The asynchronous forms throughout: a busy sample cannot stall Emacs.
void place(HWND hwnd, const RECT &r)
{
	int w = std::max<LONG>(r.right - r.left, 1), h = std::max<LONG>(r.bottom - r.top, 1);
	SetWindowPos(hwnd, HWND_TOP, r.left, r.top, w, h, SWP_NOACTIVATE | SWP_ASYNCWINDOWPOS);
}

void show(HWND hwnd, bool visible)
{
	ShowWindowAsync(hwnd, visible ? SW_SHOWNA : SW_HIDE);
}

std::string stem(const std::string &exe)
{
	auto slash = exe.find_last_of("\\/");
	auto name  = slash == std::string::npos ? exe : exe.substr(slash + 1);
	auto dot   = name.find_last_of('.');
	return dot == std::string::npos ? name : name.substr(0, dot);
}

void run(const std::string &exe, const std::string &args, const std::string &cwd, HWND parent, Commands &commands,
         ViewState &state)
{
	const std::string name = stem(exe);
	// Hidden from the start: Win32Application::Run shows its window with the
	// nCmdShow this sets, so it never flashes up on the desktop.
	STARTUPINFOW startup{sizeof startup};
	startup.dwFlags     = STARTF_USESHOWWINDOW;
	startup.wShowWindow = SW_HIDE;
	PROCESS_INFORMATION info{};
	std::wstring        command_line = L"\"" + widen(exe) + L"\" " + widen(args);
	if (!CreateProcessW(widen(exe).c_str(), command_line.data(), nullptr, nullptr, FALSE, 0, nullptr,
	                    widen(cwd).c_str(), &startup, &info))
	{
		throw HResultError(HRESULT_FROM_WIN32(GetLastError()), "cannot start " + exe);
	}
	CloseHandle(info.hThread);
	HANDLE process = info.hProcess;
	state.pid      = info.dwProcessId;

	HWND        window = nullptr;
	RECT        bounds{};
	bool        have_bounds = false, visible = false;
	auto        started     = std::chrono::steady_clock::now();
	std::string failure;
	for (bool running = true; running;)
	{
		while (auto command = commands.try_receive())
		{
			switch (command->kind)
			{
				case Command::Bounds:
					bounds      = command->bounds;
					have_bounds = true;
					if (window)
					{
						place(window, bounds);
					}
					break;
				case Command::Visible:
					visible = command->visible;
					if (window)
					{
						show(window, visible);
					}
					break;
				case Command::Parent:
					parent = command->parent;
					if (window)
					{
						SetParent(window, parent);
					}
					if (command->done)
					{
						command->done->set_value();
					}
					break;
				case Command::Close:
					running = false;
					break;
			}
		}
		if (!running)
		{
			break;
		}
		if (!window)
		{
			if (HWND found = find_main_window(info.dwProcessId))
			{
				adopt(found, parent);
				if (have_bounds)
				{
					place(found, bounds);
				}
				show(found, visible);
				window = found;
				state.set_status("running " + name + " (pid " + std::to_string(info.dwProcessId) + ")");
			}
			else if (std::chrono::steady_clock::now() - started > std::chrono::seconds(60))
			{
				failure = name + " opened no window within 60 s";
				break;
			}
		}
		// The sample ended by itself (closed, or failed to start).
		if (WaitForSingleObject(process, 30) == WAIT_OBJECT_0)
		{
			DWORD code = 0;
			GetExitCodeProcess(process, &code);
			state.set_status(window ? "exited (code " + std::to_string(code) + ")" :
			                          "error: " + name + " exited (code " + std::to_string(code) + ") before opening a window");
			CloseHandle(process);
			return;
		}
	}
	// Close: ask the sample to quit, then make sure it does.
	if (window)
	{
		PostMessageW(window, WM_CLOSE, 0, 0);
	}
	if (WaitForSingleObject(process, 3000) != WAIT_OBJECT_0)
	{
		TerminateProcess(process, 1);
		WaitForSingleObject(process, 2000);
	}
	CloseHandle(process);
	state.set_status(failure.empty() ? std::string("closed") : "error: " + failure);
}
}        // namespace

std::unique_ptr<ViewHandle> open(const std::string &exe, const std::string &args, const std::string &cwd, HWND parent)
{
	auto view = std::make_unique<ViewHandle>();
	view->id  = new_view_id();
	std::thread([exe, args, cwd, parent, commands = view->commands, state = view->state] {
		try
		{
			run(exe, args, cwd, parent, *commands, *state);
		}
		catch (const std::exception &e)
		{
			state->set_status(std::string("error: ") + e.what());
		}
		commands->finish();
	}).detach();
	return view;
}
}        // namespace winine::dxs
