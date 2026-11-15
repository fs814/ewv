// winine_native.dll: the Emacs dynamic module. Defines the winine-native-*
// functions, the same set (and the same arguments) as ewv's ewv-native-*
// (ewv's src/lisp.rs, dx12_lisp.rs, vks_lisp.rs), so winine's Lisp is ewv's
// with the prefix renamed.
#include "dx12/dx12.h"
#include "dxs.h"
#include "lisp.h"
#include "vks.h"
#include "webview.h"

#include <algorithm>
#include <memory>
#include <vector>

// emacs-module.h declares both symbols, so they are exported by name here
// rather than with __declspec(dllexport) (which would redeclare them).
extern "C" int plugin_is_GPL_compatible;
int plugin_is_GPL_compatible;
#pragma comment(linker, "/EXPORT:plugin_is_GPL_compatible,DATA")
#pragma comment(linker, "/EXPORT:emacs_module_init")

namespace winine
{
namespace
{
// Lisp thread only.
std::vector<std::unique_ptr<Webview>>    g_webviews;
std::vector<std::unique_ptr<ViewHandle>> g_dx12_views;
std::vector<std::unique_ptr<ViewHandle>> g_vks_views;
std::vector<std::unique_ptr<ViewHandle>> g_dxs_views;

Webview &webview(Lisp &lisp, emacs_value id_value)
{
	int64_t id = lisp.to_int(id_value);
	for (auto &w : g_webviews)
	{
		if (w->id() == id)
		{
			return *w;
		}
	}
	throw std::runtime_error("no webview with id(" + std::to_string(id) + ") found");
}

ViewHandle &view(std::vector<std::unique_ptr<ViewHandle>> &views, Lisp &lisp, emacs_value id_value, const char *kind)
{
	int64_t id = lisp.to_int(id_value);
	for (auto &v : views)
	{
		if (v->id == id)
		{
			return *v;
		}
	}
	throw std::runtime_error(std::string("no ") + kind + " view with id(" + std::to_string(id) + ") found");
}

void close_view(std::vector<std::unique_ptr<ViewHandle>> &views, Lisp &lisp, emacs_value id_value, int seconds = 3)
{
	int64_t id = lisp.to_int(id_value);
	auto    it = std::find_if(views.begin(), views.end(), [&](auto &v) { return v->id == id; });
	if (it != views.end())
	{
		// Wait for the render thread, so a new view can start right after and
		// Emacs never exits with one mid-frame.
		(*it)->close(true, seconds);
		views.erase(it);
	}
}

void finalize_environment(void *ptr) noexcept
{
	delete static_cast<Environment *>(ptr);
}

Environment &environment(Lisp &lisp, emacs_value value)
{
	if (lisp.env->get_user_finalizer(lisp.env, value) != finalize_environment)
	{
		lisp.check();
		throw std::runtime_error("not a winine environment (make one with winine-native-environment-new1)");
	}
	return *static_cast<Environment *>(lisp.env->get_user_ptr(lisp.env, value));
}

// --- environment / webview -------------------------------------------------

emacs_value environment_new1(Lisp &lisp, ptrdiff_t, emacs_value *args)
{
	auto exe  = lisp.to_optional_string(lisp.plist_get(args[0], ":browser-executable-folder"));
	auto data = lisp.to_optional_string(lisp.plist_get(args[0], ":user-data-folder"));
	bool ext  = !lisp.is_nil(lisp.plist_get(args[0], ":are-browser-extensions-enabled"));
	log("browser_executable_folder = %s", exe ? exe->c_str() : "None");
	log("user_data_folder = %s", data ? data->c_str() : "None");
	log("are_browser_extensions_enabled = %s", ext ? "true" : "false");
	Environment *created = Environment::create(exe, data, ext);
	emacs_value  value   = lisp.env->make_user_ptr(lisp.env, finalize_environment, created);
	lisp.check();
	return value;
}

emacs_value webview_new(Lisp &lisp, ptrdiff_t, emacs_value *args)
{
	HWND  hwnd = frame_hwnd(lisp, args[0]);
	auto &env  = environment(lisp, args[1]);
	g_webviews.push_back(std::make_unique<Webview>(hwnd, env));
	return lisp.integer(g_webviews.back()->id());
}

#define WININE_VOID(name, body)                                     \
	emacs_value name(Lisp &lisp, ptrdiff_t, emacs_value *args)      \
	{                                                               \
		body;                                                       \
		return lisp.nil();                                          \
	}

WININE_VOID(webview_reparent, webview(lisp, args[0]).reparent(frame_hwnd(lisp, args[1])))
WININE_VOID(webview_resize, webview(lisp, args[0]).resize(rect_from_lisp(lisp, args[1])))
WININE_VOID(webview_focus, webview(lisp, args[0]).focus())
WININE_VOID(webview_load_sync, webview(lisp, args[0]).load_sync(lisp.to_string(args[1])))
WININE_VOID(webview_set_on_new_window_requested, webview(lisp, args[0]).set_on_new_window_requested(lisp, args[1]))
WININE_VOID(webview_set_on_focus, webview(lisp, args[0]).set_on_focus(lisp, args[1]))
WININE_VOID(webview_set_on_navigation_starting, webview(lisp, args[0]).set_on_navigation_starting(lisp, args[1]))
WININE_VOID(webview_set_on_history_changed, webview(lisp, args[0]).set_on_history_changed(lisp, args[1]))
WININE_VOID(webview_load, webview(lisp, args[0]).load(lisp, lisp.to_string(args[1]), args[2]))
WININE_VOID(webview_set_visible, webview(lisp, args[0]).set_visible(!lisp.is_nil(args[1])))
WININE_VOID(webview_eval_js_sync, webview(lisp, args[0]).eval_js_sync(lisp.to_string(args[1])))
WININE_VOID(webview_eval_js, webview(lisp, args[0]).eval_js_cdp(lisp.to_string(args[1])))
WININE_VOID(webview_add_extension, webview(lisp, args[0]).add_extension(lisp.to_string(args[1])))
WININE_VOID(webview_go_forward, webview(lisp, args[0]).go_forward())
WININE_VOID(webview_go_back, webview(lisp, args[0]).go_back())
WININE_VOID(webview_reload, webview(lisp, args[0]).reload())
WININE_VOID(webview_set_on_web_message, webview(lisp, args[0]).set_on_web_message(lisp, args[1]))
WININE_VOID(webview_post_web_message, webview(lisp, args[0]).post_web_message_json(lisp.to_string(args[1])))
WININE_VOID(webview_add_script, webview(lisp, args[0]).add_script_on_document_created(lisp.to_string(args[1])))
WININE_VOID(webview_execute_script, webview(lisp, args[0]).execute_script(lisp, lisp.to_string(args[1]), args[2]))
WININE_VOID(webview_set_color_scheme, webview(lisp, args[0]).set_color_scheme(lisp.to_string(args[1])))

emacs_value webview_is_visible(Lisp &lisp, ptrdiff_t, emacs_value *args)
{
	return lisp.boolean(webview(lisp, args[0]).visible());
}

emacs_value webview_get_document_title(Lisp &lisp, ptrdiff_t, emacs_value *args)
{
	return lisp.string(webview(lisp, args[0]).document_title());
}

emacs_value webview_get_url(Lisp &lisp, ptrdiff_t, emacs_value *args)
{
	return lisp.string(webview(lisp, args[0]).url());
}

emacs_value webview_can_go_forward(Lisp &lisp, ptrdiff_t, emacs_value *args)
{
	return lisp.boolean(webview(lisp, args[0]).can_go_forward());
}

emacs_value webview_can_go_back(Lisp &lisp, ptrdiff_t, emacs_value *args)
{
	return lisp.boolean(webview(lisp, args[0]).can_go_back());
}

emacs_value webview_set_default_background_color(Lisp &lisp, ptrdiff_t, emacs_value *args)
{
	auto byte = [&](emacs_value v) {
		int64_t n = lisp.to_int(v);
		if (n < 0 || n > 255)
		{
			throw std::runtime_error("color component out of range 0..255: " + std::to_string(n));
		}
		return static_cast<uint8_t>(n);
	};
	webview(lisp, args[0]).set_default_background_color(byte(args[1]), byte(args[2]), byte(args[3]), byte(args[4]));
	return lisp.nil();
}

emacs_value webview_close(Lisp &lisp, ptrdiff_t, emacs_value *args)
{
	int64_t id = lisp.to_int(args[0]);
	auto    it = std::find_if(g_webviews.begin(), g_webviews.end(), [&](auto &w) { return w->id() == id; });
	if (it == g_webviews.end())
	{
		throw std::runtime_error("no webview with id(" + std::to_string(id) + ") found");
	}
	(*it)->close();
	g_webviews.erase(it);
	return lisp.nil();
}

emacs_value webview_open_task_manager(Lisp &lisp, ptrdiff_t, emacs_value *)
{
	if (!g_webviews.empty())
	{
		g_webviews.front()->open_task_manager();
	}
	return lisp.nil();
}

// --- frames and events -------------------------------------------------------

emacs_value focus_frame(Lisp &lisp, ptrdiff_t, emacs_value *args)
{
	SetFocus(frame_hwnd(lisp, args[0]));
	return lisp.nil();
}

emacs_value print(Lisp &lisp, ptrdiff_t, emacs_value *args)
{
	log("lisp: %s", lisp.to_string(args[0]).c_str());
	return lisp.nil();
}

emacs_value init_frame_thread_hook(Lisp &lisp, ptrdiff_t, emacs_value *)
{
	install_frame_thread_hook(frame_hwnd(lisp, lisp.call("selected-frame")));
	return lisp.nil();
}

emacs_value process_events_fn(Lisp &lisp, ptrdiff_t, emacs_value *)
{
	process_events(lisp);
	return lisp.nil();
}

// --- Direct3D 12 demos -------------------------------------------------------

emacs_value dx12_open(Lisp &lisp, ptrdiff_t, emacs_value *args)
{
	std::string demo = lisp.to_string(args[0]);
	HWND        hwnd = frame_hwnd(lisp, args[1]);
	g_dx12_views.push_back(dx12::open(demo, hwnd));
	return lisp.integer(g_dx12_views.back()->id);
}

// --- Vulkan samples ----------------------------------------------------------

emacs_value vks_open(Lisp &lisp, ptrdiff_t, emacs_value *args)
{
	std::string sample  = lisp.to_string(args[0]);
	HWND        hwnd    = frame_hwnd(lisp, args[1]);
	std::string library = lisp.to_string(args[2]);
	std::string root    = lisp.to_string(args[3]);
	g_vks_views.push_back(vks::open(sample, hwnd, library, root));
	return lisp.integer(g_vks_views.back()->id);
}

// The view functions are the same for both kinds.
#define WININE_VIEW_FUNCTIONS(prefix, views, kind)                                                           \
	emacs_value prefix##_resize(Lisp &lisp, ptrdiff_t, emacs_value *args)                                     \
	{                                                                                                         \
		view(views, lisp, args[0], kind).resize(rect_from_lisp(lisp, args[1]));                               \
		return lisp.nil();                                                                                    \
	}                                                                                                         \
	emacs_value prefix##_set_visible(Lisp &lisp, ptrdiff_t, emacs_value *args)                                \
	{                                                                                                         \
		view(views, lisp, args[0], kind).set_visible(!lisp.is_nil(args[1]));                                  \
		return lisp.nil();                                                                                    \
	}                                                                                                         \
	emacs_value prefix##_reparent(Lisp &lisp, ptrdiff_t, emacs_value *args)                                   \
	{                                                                                                         \
		HWND hwnd = frame_hwnd(lisp, args[1]);                                                                \
		view(views, lisp, args[0], kind).reparent(hwnd);                                                      \
		return lisp.nil();                                                                                    \
	}                                                                                                         \
	emacs_value prefix##_status(Lisp &lisp, ptrdiff_t, emacs_value *args)                                     \
	{                                                                                                         \
		return lisp.string(view(views, lisp, args[0], kind).status());                                        \
	}                                                                                                         \
	emacs_value prefix##_frame_count(Lisp &lisp, ptrdiff_t, emacs_value *args)                                \
	{                                                                                                         \
		return lisp.integer(static_cast<int64_t>(view(views, lisp, args[0], kind).frames()));                 \
	}                                                                                                         \
	emacs_value prefix##_close(Lisp &lisp, ptrdiff_t, emacs_value *args)                                      \
	{                                                                                                         \
		close_view(views, lisp, args[0]);                                                                     \
		return lisp.nil();                                                                                    \
	}

WININE_VIEW_FUNCTIONS(dx12, g_dx12_views, "dx12")
WININE_VIEW_FUNCTIONS(vks, g_vks_views, "vulkan")
WININE_VIEW_FUNCTIONS(dxs, g_dxs_views, "dxsample")

// --- DirectX-Graphics-Samples ------------------------------------------------

emacs_value dxs_open(Lisp &lisp, ptrdiff_t, emacs_value *args)
{
	std::string exe  = lisp.to_string(args[0]);
	std::string tail = lisp.to_string(args[1]);
	std::string cwd  = lisp.to_string(args[2]);
	HWND        hwnd = frame_hwnd(lisp, args[3]);
	g_dxs_views.push_back(dxs::open(exe, tail, cwd, hwnd));
	return lisp.integer(g_dxs_views.back()->id);
}

emacs_value dxs_pid(Lisp &lisp, ptrdiff_t, emacs_value *args)
{
	return lisp.integer(view(g_dxs_views, lisp, args[0], "dxsample").state->pid.load());
}

// Closing waits for the sample to exit (WM_CLOSE, then terminated after 3 s).
emacs_value dxs_close_and_wait(Lisp &lisp, ptrdiff_t, emacs_value *args)
{
	close_view(g_dxs_views, lisp, args[0], 6);
	return lisp.nil();
}

struct Definition
{
	const char *name;
	ptrdiff_t   min_args, max_args;
	Function    function;
	const char *doc;
};

const Definition DEFINITIONS[] = {
    {"winine-native-environment-new1", 1, 1, environment_new1,
     "Create a WebView2 environment from OPTIONS, a plist with :browser-executable-folder,\n"
     ":user-data-folder and :are-browser-extensions-enabled.\n\n(fn OPTIONS)"},
    {"winine-native-webview-new", 2, 2, webview_new, "Create a webview in FRAME with ENVIRONMENT; return its id.\n\n(fn FRAME ENVIRONMENT)"},
    {"winine-native-webview-reparent", 2, 2, webview_reparent, "Move webview ID to FRAME.\n\n(fn ID FRAME)"},
    {"winine-native-webview-resize", 2, 2, webview_resize, "Place webview ID at BOUNDS (LEFT TOP RIGHT BOTTOM).\n\n(fn ID BOUNDS)"},
    {"winine-native-webview-focus", 1, 1, webview_focus, "Give webview ID the keyboard focus.\n\n(fn ID)"},
    {"winine-native-webview-load-sync", 2, 2, webview_load_sync, "Navigate webview ID to URL and wait until loaded.\n\n(fn ID URL)"},
    {"winine-native-webview-set-on-new-window-requested", 2, 2, webview_set_on_new_window_requested,
     "Call CALLBACK with (URI FEATURES) when a page opens a window; non-nil means handled.\n\n(fn ID CALLBACK)"},
    {"winine-native-webview-set-on-focus", 2, 2, webview_set_on_focus, "Call CALLBACK with t or nil when webview ID gains or loses focus.\n\n(fn ID CALLBACK)"},
    {"winine-native-webview-set-on-navigation-starting", 2, 2, webview_set_on_navigation_starting,
     "Call CALLBACK with the URI of every navigation that starts.\n\n(fn ID CALLBACK)"},
    {"winine-native-webview-set-on-history-changed", 2, 2, webview_set_on_history_changed,
     "Call CALLBACK with no arguments when the history changes.\n\n(fn ID CALLBACK)"},
    {"winine-native-webview-load", 3, 3, webview_load, "Navigate webview ID to URL; call CALLBACK with (TITLE URL) when done.\n\n(fn ID URL CALLBACK)"},
    {"winine-native-webview-set-visible", 2, 2, webview_set_visible, "Show (VISIBLE non-nil) or hide webview ID.\n\n(fn ID VISIBLE)"},
    {"winine-native-webview-is-visible", 1, 1, webview_is_visible, "Non-nil if webview ID is visible.\n\n(fn ID)"},
    {"winine-native-webview-get-document-title", 1, 1, webview_get_document_title, "The page title of webview ID.\n\n(fn ID)"},
    {"winine-native-webview-set-default-background-color", 5, 5, webview_set_default_background_color,
     "Set webview ID's background to A R G B (0..255).\n\n(fn ID A R G B)"},
    {"winine-native-webview-get-url", 1, 1, webview_get_url, "The URL of webview ID.\n\n(fn ID)"},
    {"winine-native-webview-eval-js-sync", 2, 2, webview_eval_js_sync, "Run JS in webview ID and wait (result is logged).\n\n(fn ID JS)"},
    {"winine-native-webview-eval-js", 3, 3, webview_eval_js,
     "Evaluate JS with the DevTools protocol (Runtime.evaluate); CALLBACK is unused, as in ewv.\n\n(fn ID JS CALLBACK)"},
    {"winine-native-webview-close", 1, 1, webview_close, "Close webview ID.\n\n(fn ID)"},
    {"winine-native-webview-open-task-manager", 0, 0, webview_open_task_manager, "Open the browser task manager."},
    {"winine-native-webview-add-extension", 2, 2, webview_add_extension, "Add the unpacked browser extension at PATH.\n\n(fn ID PATH)"},
    {"winine-native-webview-go-forward", 1, 1, webview_go_forward, "Go forward in webview ID.\n\n(fn ID)"},
    {"winine-native-webview-go-back", 1, 1, webview_go_back, "Go back in webview ID.\n\n(fn ID)"},
    {"winine-native-webview-can-go-forward", 1, 1, webview_can_go_forward, "Non-nil if webview ID can go forward.\n\n(fn ID)"},
    {"winine-native-webview-can-go-back", 1, 1, webview_can_go_back, "Non-nil if webview ID can go back.\n\n(fn ID)"},
    {"winine-native-webview-reload", 1, 1, webview_reload, "Reload webview ID.\n\n(fn ID)"},
    {"winine-native-webview-set-on-web-message", 2, 2, webview_set_on_web_message,
     "Call CALLBACK with (SOURCE-URI JSON) for every chrome.webview.postMessage.\n\n(fn ID CALLBACK)"},
    {"winine-native-webview-post-web-message", 2, 2, webview_post_web_message,
     "Send JSON (one JSON value as a string) to the page as a `message' event.\n\n(fn ID JSON)"},
    {"winine-native-webview-add-script", 2, 2, webview_add_script, "Run JS at the start of every document from now on.\n\n(fn ID JS)"},
    {"winine-native-webview-execute-script", 3, 3, webview_execute_script,
     "Run JS in the page; call CALLBACK with its result as a JSON string.\n\n(fn ID JS CALLBACK)"},
    {"winine-native-webview-set-color-scheme", 2, 2, webview_set_color_scheme,
     "SCHEME is \"dark\", \"light\" or \"auto\"; applies to the whole profile.\n\n(fn ID SCHEME)"},
    {"winine-native-focus-frame", 1, 1, focus_frame, "Give FRAME's window the keyboard focus.\n\n(fn FRAME)"},
    {"winine-native-print", 1, 1, print, "Print MESSAGE to stdout.\n\n(fn MESSAGE)"},
    {"winine-native-init-frame-thread-hook", 0, 0, init_frame_thread_hook,
     "Install the hook that gives a clicked frame the focus back from a webview."},
    {"winine-native-process-events", 0, 0, process_events_fn, "Run the queued webview callbacks."},
    {"winine-native-dx12-open", 2, 2, dx12_open,
     "Open the Direct3D 12 demo DEMO (\"triangle\" or \"raytracing\") in FRAME; return its id.\n\n(fn DEMO FRAME)"},
    {"winine-native-dx12-resize", 2, 2, dx12_resize, "Place demo view ID at BOUNDS.\n\n(fn ID BOUNDS)"},
    {"winine-native-dx12-set-visible", 2, 2, dx12_set_visible, "Show or hide demo view ID.\n\n(fn ID VISIBLE)"},
    {"winine-native-dx12-reparent", 2, 2, dx12_reparent, "Move demo view ID to FRAME.\n\n(fn ID FRAME)"},
    {"winine-native-dx12-status", 1, 1, dx12_status, "\"starting\", \"running on <GPU>\", \"error: ...\" or \"closed\".\n\n(fn ID)"},
    {"winine-native-dx12-frame-count", 1, 1, dx12_frame_count, "Frames demo view ID has presented.\n\n(fn ID)"},
    {"winine-native-dx12-close", 1, 1, dx12_close, "Stop demo view ID.\n\n(fn ID)"},
    {"winine-native-vks-open", 4, 4, vks_open,
     "Open Vulkan sample SAMPLE in FRAME from LIBRARY with ROOT; return its id.\n\n(fn SAMPLE FRAME LIBRARY ROOT)"},
    {"winine-native-vks-resize", 2, 2, vks_resize, "Place Vulkan view ID at BOUNDS.\n\n(fn ID BOUNDS)"},
    {"winine-native-vks-set-visible", 2, 2, vks_set_visible, "Show or hide Vulkan view ID.\n\n(fn ID VISIBLE)"},
    {"winine-native-vks-reparent", 2, 2, vks_reparent, "Move Vulkan view ID to FRAME.\n\n(fn ID FRAME)"},
    {"winine-native-vks-status", 1, 1, vks_status, "\"starting\", \"running <sample>\", \"error: ...\" or \"closed\".\n\n(fn ID)"},
    {"winine-native-vks-frame-count", 1, 1, vks_frame_count, "Frames the Vulkan sample has drawn.\n\n(fn ID)"},
    {"winine-native-vks-close", 1, 1, vks_close, "Stop Vulkan view ID and wait for it.\n\n(fn ID)"},
    {"winine-native-dxs-open", 4, 4, dxs_open,
     "Start EXE (a built DirectX-Graphics-Samples program) with ARGS in CWD and embed its window in FRAME;\n"
     "return the view's id.\n\n(fn EXE ARGS CWD FRAME)"},
    {"winine-native-dxs-resize", 2, 2, dxs_resize, "Place sample view ID at BOUNDS.\n\n(fn ID BOUNDS)"},
    {"winine-native-dxs-set-visible", 2, 2, dxs_set_visible, "Show or hide sample view ID.\n\n(fn ID VISIBLE)"},
    {"winine-native-dxs-reparent", 2, 2, dxs_reparent, "Move sample view ID to FRAME.\n\n(fn ID FRAME)"},
    {"winine-native-dxs-status", 1, 1, dxs_status,
     "\"starting\", \"running <sample> (pid N)\", \"exited (code N)\", \"error: ...\" or \"closed\".\n\n(fn ID)"},
    {"winine-native-dxs-pid", 1, 1, dxs_pid, "The sample's process id (0 before it started).\n\n(fn ID)"},
    {"winine-native-dxs-close", 1, 1, dxs_close_and_wait, "Close sample view ID and wait for it to exit.\n\n(fn ID)"},
};
}        // namespace
}        // namespace winine

extern "C" int emacs_module_init(struct emacs_runtime *runtime)
{
	if (runtime->size < static_cast<ptrdiff_t>(sizeof *runtime))
	{
		return 1;
	}
	emacs_env *env = runtime->get_environment(runtime);
	if (env->size < static_cast<ptrdiff_t>(sizeof(struct emacs_env_25)))
	{
		return 2;
	}
	// WebView2 needs a single-threaded apartment on the Lisp thread.
	CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

	winine::Lisp lisp(env);
	for (const auto &d : winine::DEFINITIONS)
	{
		winine::defun(lisp, d.name, d.min_args, d.max_args, d.function, d.doc);
	}
	emacs_value feature = env->intern(env, "winine-native");
	env->funcall(env, env->intern(env, "provide"), 1, &feature);
	return 0;
}
