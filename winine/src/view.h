// What the Direct3D 12 and Vulkan views share: each is a child window of an
// Emacs frame owned by its own render thread, which takes commands from the
// Lisp-side handle (place, show, move to another frame, close) and reports a
// status string and a frame count back. Mirrors ewv's src/dx12/mod.rs and
// src/vks.rs.
#pragma once

#include "common.h"

#include <atomic>
#include <chrono>
#include <deque>
#include <future>
#include <memory>
#include <mutex>
#include <optional>

namespace winine
{
struct Command
{
	enum Kind
	{
		Bounds,
		Visible,
		Parent,
		Close
	} kind;
	RECT                               bounds{};
	bool                               visible = false;
	HWND                               parent  = nullptr;
	std::shared_ptr<std::promise<void>> done;        // Parent: set once moved
};

// Lisp -> render thread. `send' fails once the render thread has exited.
class Commands
{
  public:
	bool send(Command command)
	{
		std::lock_guard<std::mutex> lock(mutex);
		if (finished)
		{
			return false;
		}
		queue.push_back(std::move(command));
		return true;
	}
	std::optional<Command> try_receive()
	{
		std::lock_guard<std::mutex> lock(mutex);
		if (queue.empty())
		{
			return std::nullopt;
		}
		Command command = std::move(queue.front());
		queue.pop_front();
		return command;
	}
	// The render thread is done: later sends fail, and `wait_finished' returns.
	void finish()
	{
		{
			std::lock_guard<std::mutex> lock(mutex);
			finished = true;
		}
		finished_signal.set_value();
	}
	bool wait_finished(std::chrono::milliseconds timeout)
	{
		return finished_future.wait_for(timeout) == std::future_status::ready;
	}

  private:
	std::mutex          mutex;
	std::deque<Command> queue;
	bool                finished = false;
	std::promise<void>  finished_signal;
	std::shared_future<void> finished_future = finished_signal.get_future().share();
};

// Render thread -> Lisp.
struct ViewState
{
	std::mutex            mutex;
	std::string           status = "starting";
	std::atomic<uint64_t> frames{0};
	std::atomic<uint32_t> pid{0};        // DirectX-Graphics-Samples views: the sample's process

	void set_status(std::string value)
	{
		std::lock_guard<std::mutex> lock(mutex);
		status = std::move(value);
	}
	std::string get_status()
	{
		std::lock_guard<std::mutex> lock(mutex);
		return status;
	}
};

// The Lisp-thread handle of one view.
class ViewHandle
{
  public:
	int64_t id = 0;

	void resize(const RECT &bounds)
	{
		Command c{Command::Bounds};
		c.bounds = bounds;
		commands->send(c);
	}
	void set_visible(bool visible)
	{
		Command c{Command::Visible};
		c.visible = visible;
		commands->send(c);
	}
	// Waits (at most 2 s) for the render thread to move the window: the caller
	// may be about to delete the old frame, which destroys its child windows.
	void reparent(HWND parent)
	{
		Command c{Command::Parent};
		c.parent = parent;
		c.done   = std::make_shared<std::promise<void>>();
		auto f   = c.done->get_future();
		if (commands->send(std::move(c)))
		{
			f.wait_for(std::chrono::seconds(2));
		}
	}
	// Ask the render thread to stop; with WAIT, until it has (at most SECONDS).
	void close(bool wait, int seconds = 3)
	{
		if (commands->send(Command{Command::Close}) && wait)
		{
			commands->wait_finished(std::chrono::seconds(seconds));
		}
	}
	std::string status()
	{
		return state->get_status();
	}
	uint64_t frames()
	{
		return state->frames.load();
	}

	std::shared_ptr<Commands>  commands = std::make_shared<Commands>();
	std::shared_ptr<ViewState> state    = std::make_shared<ViewState>();
};

int64_t new_view_id();

// A child window of PARENT of the window class NAME (registered once).
// DISABLED lets mouse input fall through to the Emacs frame.
HWND create_view_window(const wchar_t *class_name, WNDPROC procedure, HWND parent, bool disabled);

// Apply one command to the view's window; returns false for Close.
// SIZE/VISIBLE are updated for Bounds/Visible.
bool apply_command(HWND hwnd, Command &command, std::pair<uint32_t, uint32_t> &size, bool &visible);

// Drain the window's messages; returns false on WM_QUIT (window destroyed).
bool pump_view_messages();
}        // namespace winine
