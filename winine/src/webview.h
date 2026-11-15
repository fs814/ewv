// Edge WebView2 views in Emacs frames: the C++ counterpart of ewv's
// src/webview.rs. One Webview is a WebView2 controller whose parent window is
// an Emacs frame; winine-browser.el places it over an Emacs window.
#pragma once

#include "lisp.h"

#include <WebView2.h>

#include <memory>
#include <optional>
#include <string>

namespace winine
{
// A WebView2 environment (browser process + profile folder). Lisp holds it as
// a user-ptr made by winine-native-environment-new1.
struct Environment
{
	ComPtr<ICoreWebView2Environment> raw;

	static Environment *create(const std::optional<std::string> &browser_executable_folder,
	                           const std::optional<std::string> &user_data_folder,
	                           bool                              are_browser_extensions_enabled);
};

class Webview
{
  public:
	Webview(HWND parent, Environment &environment);

	int64_t id() const
	{
		return id_;
	}

	void reparent(HWND parent);
	void resize(const RECT &bounds);
	void focus();
	void set_visible(bool visible);
	bool visible();
	void close();

	void load(Lisp &lisp, const std::string &url, emacs_value callback);        // CALLBACK (TITLE URL)
	void load_sync(const std::string &url);
	void reload();
	void go_back();
	void go_forward();
	bool can_go_back();
	bool can_go_forward();
	std::string url();
	std::string document_title();

	void set_on_new_window_requested(Lisp &lisp, emacs_value callback);        // (URI FEATURES) -> handled
	void set_on_focus(Lisp &lisp, emacs_value callback);                       // (FOCUSED)
	void set_on_navigation_starting(Lisp &lisp, emacs_value callback);         // (URI)
	void set_on_history_changed(Lisp &lisp, emacs_value callback);             // ()
	void set_on_web_message(Lisp &lisp, emacs_value callback);                 // (SOURCE JSON)

	void execute_script(Lisp &lisp, const std::string &js, emacs_value callback);        // (RESULT-JSON)
	void eval_js_cdp(const std::string &js);
	void eval_js_sync(const std::string &js);
	void add_script_on_document_created(const std::string &js);
	void post_web_message_json(const std::string &json);

	void set_default_background_color(uint8_t a, uint8_t r, uint8_t g, uint8_t b);
	void set_color_scheme(const std::string &scheme);
	void add_extension(const std::string &path);
	void open_task_manager();

  private:
	ComPtr<ICoreWebView2Profile> profile();

	int64_t                         id_;
	HWND                            parent_;
	ComPtr<ICoreWebView2Controller> controller_;
	ComPtr<ICoreWebView2>           webview_;
};

// The Emacs frame's thread: a WH_GETMESSAGE hook that gives a clicked frame
// the keyboard focus back from a webview.
void install_frame_thread_hook(HWND frame);
}        // namespace winine
