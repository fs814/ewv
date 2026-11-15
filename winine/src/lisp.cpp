#include "lisp.h"

#include <exception>

namespace winine
{
emacs_value Lisp::intern(const char *name)
{
	return env->intern(env, name);
}

emacs_value Lisp::nil()
{
	return intern("nil");
}

emacs_value Lisp::t()
{
	return intern("t");
}

emacs_value Lisp::boolean(bool value)
{
	return value ? t() : nil();
}

emacs_value Lisp::integer(int64_t value)
{
	return env->make_integer(env, value);
}

emacs_value Lisp::string(std::string_view utf8)
{
	emacs_value value = env->make_string(env, utf8.data(), static_cast<ptrdiff_t>(utf8.size()));
	check();
	return value;
}

emacs_value Lisp::list(std::initializer_list<emacs_value> items)
{
	return call("list", items);
}

emacs_value Lisp::call(emacs_value function, std::initializer_list<emacs_value> args)
{
	std::vector<emacs_value> argv(args);
	emacs_value              result = env->funcall(env, function, static_cast<ptrdiff_t>(argv.size()), argv.data());
	check();
	return result;
}

emacs_value Lisp::call(const char *function, std::initializer_list<emacs_value> args)
{
	return call(intern(function), args);
}

bool Lisp::is_nil(emacs_value value)
{
	return !env->is_not_nil(env, value);
}

int64_t Lisp::to_int(emacs_value value)
{
	int64_t result = env->extract_integer(env, value);
	check();
	return result;
}

std::string Lisp::to_string(emacs_value value)
{
	ptrdiff_t size = 0;
	env->copy_string_contents(env, value, nullptr, &size);
	check();
	std::string out(static_cast<size_t>(size), '\0');
	env->copy_string_contents(env, value, out.data(), &size);
	check();
	out.resize(size > 0 ? static_cast<size_t>(size - 1) : 0);        // drop the NUL
	return out;
}

std::optional<std::string> Lisp::to_optional_string(emacs_value value)
{
	if (is_nil(value))
	{
		return std::nullopt;
	}
	return to_string(value);
}

emacs_value Lisp::plist_get(emacs_value plist, const char *key)
{
	return call("plist-get", {plist, intern(key)});
}

void Lisp::check()
{
	if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
	{
		throw LispExit{};
	}
}

GlobalRef::GlobalRef(Lisp &lisp, emacs_value value) :
    value(lisp.env->make_global_ref(lisp.env, value))
{}

void GlobalRef::free(Lisp &lisp)
{
	if (value)
	{
		lisp.env->free_global_ref(lisp.env, value);
		value = nullptr;
	}
}

// ---------------------------------------------------------------------------
// Functions
// ---------------------------------------------------------------------------

static void signal_error(Lisp &lisp, const std::string &message)
{
	emacs_env  *env  = lisp.env;
	emacs_value text = env->make_string(env, message.data(), static_cast<ptrdiff_t>(message.size()));
	emacs_value data = env->funcall(env, env->intern(env, "list"), 1, &text);
	env->non_local_exit_signal(env, env->intern(env, "error"), data);
}

static emacs_value dispatch(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data) noexcept
{
	Lisp lisp(env);
	try
	{
		return reinterpret_cast<Function>(data)(lisp, nargs, args);
	}
	catch (const LispExit &)
	{
		// Pending already.
	}
	catch (const std::exception &e)
	{
		signal_error(lisp, e.what());
	}
	catch (...)
	{
		signal_error(lisp, "winine: unknown C++ exception");
	}
	return env->intern(env, "nil");
}

void defun(Lisp &lisp, const char *name, ptrdiff_t min_args, ptrdiff_t max_args, Function function, const char *doc)
{
	emacs_env  *env = lisp.env;
	emacs_value fn  = env->make_function(env, min_args, max_args, dispatch, doc, reinterpret_cast<void *>(function));
	emacs_value args[] = {env->intern(env, name), fn};
	env->funcall(env, env->intern(env, "defalias"), 2, args);
}

// ---------------------------------------------------------------------------
// Event queues (Lisp thread only)
// ---------------------------------------------------------------------------

static std::vector<Event> &events()
{
	static std::vector<Event> queue;
	return queue;
}

static std::vector<Event> &callbacks()
{
	static std::vector<Event> queue;
	return queue;
}

void queue_event(Event event)
{
	events().push_back(std::move(event));
}

void queue_callback(Event callback)
{
	callbacks().push_back(std::move(callback));
}

void notify_emacs(HWND hwnd)
{
	PostMessageW(hwnd, WM_INPUTLANGCHANGE, 0, 0);
}

void process_events(Lisp &lisp)
{
	emacs_env  *env           = lisp.env;
	bool        failed        = false;
	emacs_value error_symbol  = nullptr;
	emacs_value error_data    = nullptr;
	auto        run_all       = [&](std::vector<Event> &queue) {
        // Take the queue before running it: a callback may queue more (or
        // pump messages that do).
        std::vector<Event> taken;
        taken.swap(queue);
        for (auto &event : taken)
        {
            try
            {
                event(lisp);
            }
            catch (const LispExit &)
            {
            }
            catch (const std::exception &e)
            {
                signal_error(lisp, e.what());
            }
            if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
            {
                emacs_value symbol, data;
                env->non_local_exit_get(env, &symbol, &data);
                env->non_local_exit_clear(env);
                if (!failed)
                {
                    failed       = true;
                    error_symbol = symbol;
                    error_data   = data;
                }
            }
        }
	};
	run_all(events());
	run_all(callbacks());
	if (failed)
	{
		env->non_local_exit_signal(env, error_symbol, error_data);
		throw LispExit{};
	}
}

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

HWND frame_hwnd(Lisp &lisp, emacs_value frame)
{
	std::string id = lisp.to_string(lisp.call("frame-parameter", {frame, lisp.intern("window-id")}));
	return reinterpret_cast<HWND>(static_cast<intptr_t>(std::stoll(id)));
}

RECT rect_from_lisp(Lisp &lisp, emacs_value value)
{
	if (lisp.is_nil(lisp.call("listp", {value})))
	{
		emacs_value data = lisp.list({lisp.intern("list"), value});
		lisp.env->non_local_exit_signal(lisp.env, lisp.intern("wrong-type-argument"), data);
		throw LispExit{};
	}
	RECT r{};
	r.left   = static_cast<LONG>(lisp.to_int(lisp.call("nth", {lisp.integer(0), value})));
	r.top    = static_cast<LONG>(lisp.to_int(lisp.call("nth", {lisp.integer(1), value})));
	r.right  = static_cast<LONG>(lisp.to_int(lisp.call("nth", {lisp.integer(2), value})));
	r.bottom = static_cast<LONG>(lisp.to_int(lisp.call("nth", {lisp.integer(3), value})));
	return r;
}
}        // namespace winine
