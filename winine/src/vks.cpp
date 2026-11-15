#include "vks.h"

#include <atomic>
#include <mutex>
#include <thread>
#include <vector>

namespace winine::vks
{
namespace
{
// ewv-vulkan-samples.dll's C interface (ewv's src/vulkan/ewv/ewv_vulkan_samples.h).
using StartFn  = int (*)(void *, void *, const char *, const char *, uint32_t, uint32_t, float, char *, size_t);
using FrameFn  = int (*)(char *, size_t);
using ResizeFn = void (*)(uint32_t, uint32_t);
using MouseFn  = void (*)(int, float, float);
using StopFn   = void (*)();

struct Api
{
	StartFn  start  = nullptr;
	FrameFn  frame  = nullptr;
	ResizeFn resize = nullptr;
	MouseFn  mouse  = nullptr;
	StopFn   stop   = nullptr;
};

// Loaded once per Emacs session: it cannot be unloaded while a sample may
// still be on the stack, and the framework keeps global state.
const Api &load_api(const std::string &path)
{
	static std::mutex  mutex;
	static bool        tried = false;
	static Api         api;
	static std::string failure;
	std::lock_guard<std::mutex> lock(mutex);
	if (!tried)
	{
		tried          = true;
		HMODULE module = LoadLibraryW(widen(path).c_str());
		if (!module)
		{
			failure = "cannot load " + path + " (build it with ewv's src\\vulkan\\build.ps1)";
		}
		else
		{
			auto sym = [&](const char *name) -> FARPROC {
				FARPROC p = GetProcAddress(module, name);
				if (!p && failure.empty())
				{
					failure = path + " has no " + name;
				}
				return p;
			};
			api.start  = reinterpret_cast<StartFn>(sym("ewv_vks_start"));
			api.frame  = reinterpret_cast<FrameFn>(sym("ewv_vks_frame"));
			api.resize = reinterpret_cast<ResizeFn>(sym("ewv_vks_resize"));
			api.mouse  = reinterpret_cast<MouseFn>(sym("ewv_vks_mouse"));
			api.stop   = reinterpret_cast<StopFn>(sym("ewv_vks_stop"));
		}
	}
	if (!failure.empty())
	{
		throw std::runtime_error(failure);
	}
	return api;
}

// The sample to forward mouse input to, set while one runs. Only the render
// thread touches it (the window procedure runs on that thread).
std::atomic<MouseFn> g_mouse{nullptr};
std::atomic<bool>    g_running{false};

void forward_mouse(int action, LPARAM lparam)
{
	MouseFn mouse = g_mouse.load();
	if (!g_running.load() || !mouse)
	{
		return;
	}
	float x = static_cast<float>(static_cast<short>(LOWORD(lparam)));
	float y = static_cast<float>(static_cast<short>(HIWORD(lparam)));
	mouse(action, x, y);
}

LRESULT CALLBACK view_procedure(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam)
{
	switch (msg)
	{
		case WM_ERASEBKGND:
			return 1;
		case WM_MOUSEACTIVATE:        // a click must not take focus from Emacs
			return MA_NOACTIVATE;
		case WM_LBUTTONDOWN:
			SetCapture(hwnd);
			forward_mouse(0, lparam);
			return 0;
		case WM_LBUTTONUP:
			ReleaseCapture();
			forward_mouse(1, lparam);
			return 0;
		case WM_MOUSEMOVE:
			forward_mouse(2, lparam);
			return 0;
		case WM_DESTROY:
			PostQuitMessage(0);
			return 0;
		default:
			return DefWindowProcW(hwnd, msg, wparam, lparam);
	}
}

std::string error_text(const std::vector<char> &buffer)
{
	std::string text(buffer.data());
	while (!text.empty() && (text.back() == '\n' || text.back() == ' '))
	{
		text.pop_back();
	}
	return text;
}

void render_loop(const Api &api, const std::string &sample, const std::string &root, HWND hwnd, Commands &commands,
                 ViewState &state, bool &started)
{
	bool                          visible = false;
	std::pair<uint32_t, uint32_t> size{0, 0}, drawn{0, 0};
	std::vector<char>             err(1024, '\0');
	for (;;)
	{
		while (auto command = commands.try_receive())
		{
			if (!apply_command(hwnd, *command, size, visible))
			{
				return;
			}
		}
		if (!pump_view_messages())
		{
			return;
		}
		// Start on first show, once the window has its real size: the
		// framework creates the swap chain at that size.
		if (!started && visible && size.first > 1 && size.second > 1)
		{
			float scale = static_cast<float>(std::max<UINT>(GetDpiForWindow(hwnd), 96)) / 96.0f;
			if (api.start(dll_instance(), hwnd, sample.c_str(), root.c_str(), size.first, size.second, scale,
			              err.data(), err.size()) != 0)
			{
				throw std::runtime_error(error_text(err));
			}
			started = true;
			drawn   = size;
			g_running.store(true);
			state.set_status("running " + sample);
		}
		if (started && visible)
		{
			if (size != drawn)
			{
				api.resize(size.first, size.second);
				drawn = size;
			}
			if (api.frame(err.data(), err.size()) != 0)        // presents with vsync, pacing the loop
			{
				throw std::runtime_error(error_text(err));
			}
			state.frames++;
		}
		else
		{
			MsgWaitForMultipleObjects(0, nullptr, FALSE, 30, QS_ALLINPUT);
		}
	}
}
}        // namespace

std::unique_ptr<ViewHandle> open(const std::string &sample, HWND parent, const std::string &library,
                                 const std::string &root)
{
	auto view = std::make_unique<ViewHandle>();
	view->id  = new_view_id();
	std::thread([sample, parent, library, root, commands = view->commands, state = view->state] {
		HWND       hwnd    = nullptr;
		bool       started = false;
		const Api *api     = nullptr;
		try
		{
			api = &load_api(library);
			g_mouse.store(api->mouse);
			hwnd = create_view_window(L"WinineVulkanView", view_procedure, parent, false);
			render_loop(*api, sample, root, hwnd, *commands, *state, started);
			state->set_status("closed");
		}
		catch (const std::exception &e)
		{
			state->set_status(std::string("error: ") + e.what());
		}
		g_running.store(false);
		// Only this view's own sample: a view that failed to start because
		// another one runs must leave that one alone.
		if (started && api)
		{
			api->stop();
		}
		if (hwnd)
		{
			DestroyWindow(hwnd);
		}
		commands->finish();
	}).detach();
	return view;
}
}        // namespace winine::vks
