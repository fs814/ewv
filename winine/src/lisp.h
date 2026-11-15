// The Emacs side: a thin wrapper over emacs_env, function registration, and
// the event queues that carry WebView2 callbacks to Lisp.
//
// WebView2 raises its events on the Lisp thread, but at moments when Lisp
// cannot be called (inside a message pump). So, as in ewv, each event is
// queued, the frame gets a WM_INPUTLANGCHANGE, Emacs turns that into a
// [language-change] event, and winine-core.el answers it by calling
// winine-native-process-events, which runs the queue.
#pragma once

#include "common.h"

#include <emacs-module.h>

#include <functional>
#include <initializer_list>
#include <optional>
#include <vector>

namespace winine
{
// A Lisp call exited non-locally (signal or throw). The exit stays pending in
// the env and reaches Lisp when the module function returns.
struct LispExit
{};

class Lisp
{
  public:
	explicit Lisp(emacs_env *env) :
	    env(env)
	{}

	emacs_env *env;

	emacs_value intern(const char *name);
	emacs_value nil();
	emacs_value t();
	emacs_value boolean(bool value);
	emacs_value integer(int64_t value);
	emacs_value string(std::string_view utf8);
	emacs_value list(std::initializer_list<emacs_value> items);

	emacs_value call(emacs_value function, std::initializer_list<emacs_value> args = {});
	emacs_value call(const char *function, std::initializer_list<emacs_value> args = {});

	bool                       is_nil(emacs_value value);
	int64_t                    to_int(emacs_value value);
	std::string                to_string(emacs_value value);
	std::optional<std::string> to_optional_string(emacs_value value);        // nil -> nullopt

	// (plist-get PLIST :KEY)
	emacs_value plist_get(emacs_value plist, const char *key);

	// Throw LispExit if a call left a non-local exit pending.
	void check();
};

// A Lisp value kept beyond the current call (make_global_ref).
class GlobalRef
{
  public:
	GlobalRef(Lisp &lisp, emacs_value value);
	emacs_value get() const
	{
		return value;
	}
	// Free it; only with an env (a GlobalRef left alive simply leaks, as ewv's).
	void free(Lisp &lisp);

  private:
	emacs_value value;
};

// Module functions are written as `emacs_value f(Lisp &, emacs_value *args)`.
using Function = emacs_value (*)(Lisp &lisp, ptrdiff_t nargs, emacs_value *args);

// (defalias 'NAME (make-function ...)), with C++ exceptions turned into
// Lisp errors.
void defun(Lisp &lisp, const char *name, ptrdiff_t min_args, ptrdiff_t max_args, Function function,
           const char *doc);

// Queue work for the next winine-native-process-events. `events' run first,
// then `callbacks', each queue in arrival order (as ewv's EVENTS/CALLBACKS).
using Event = std::function<void(Lisp &)>;
void queue_event(Event event);
void queue_callback(Event callback);
// Ask Emacs to call winine-native-process-events soon (via HWND's thread).
void notify_emacs(HWND hwnd);
// Run everything queued. Runs all of it even when one signals (a dropped
// callback can hold a deferral the browser waits on), then re-signals the
// first error.
void process_events(Lisp &lisp);

// The Win32 window of an Emacs frame: (frame-parameter FRAME 'window-id).
HWND frame_hwnd(Lisp &lisp, emacs_value frame);
// (LEFT TOP RIGHT BOTTOM), as window-body-pixel-edges returns.
RECT rect_from_lisp(Lisp &lisp, emacs_value value);
}        // namespace winine
