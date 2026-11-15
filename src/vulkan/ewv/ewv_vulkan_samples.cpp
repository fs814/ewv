/*
 * ewv_vulkan_samples.cpp -- runs Khronos Vulkan-Samples inside an ewv buffer.
 *
 * This is the "ewv platform" for the samples' framework: the window is a
 * Win32 child window of the Emacs frame that ewv owns (created by its render
 * thread, src/vks.rs), and ewv calls for one frame at a time instead of the
 * framework owning a main loop and a GLFW window. Ported from appine's
 * appine_vulkan_samples.cpp, which does the same with a CAMetalLayer.
 *
 * SPDX-License-Identifier: Apache-2.0  (uses the Vulkan-Samples framework)
 */
#define EWV_VKS_BUILDING
#include "ewv_vulkan_samples.h"

#include "apps.h"
#include "platform/input_events.h"
#include "platform/platform.h"
#include "platform/window.h"
#include "plugins/plugins.h"

#include <core/platform/context.hpp>
#include <filesystem/filesystem.hpp>

#include <Windows.h>

#include <cstdio>
#include <filesystem>
#include <memory>

namespace
{
// What wWinMain would pass: the arguments, and where assets/ and shaders/ are.
class EwvContext final : public vkb::PlatformContext
{
  public:
	EwvContext(std::vector<std::string> arguments, const std::string &root)
	{
		_arguments                  = std::move(arguments);
		_external_storage_directory = root;
		std::error_code ec;
		auto            tmp = std::filesystem::temp_directory_path(ec);
		_temp_directory     = ec ? std::string("temp/") : tmp.string() + "/";
	}
};

class EwvWindow final : public vkb::Window
{
  public:
	EwvWindow(const Window::Properties &properties, HINSTANCE hinstance, HWND hwnd, float scale) :
	    Window(properties), hinstance(hinstance), hwnd(hwnd), scale(scale)
	{}

	VkSurfaceKHR create_surface(vkb::core::InstanceC &instance) override
	{
		return create_surface(instance.get_handle(), VK_NULL_HANDLE);
	}

	VkSurfaceKHR create_surface(VkInstance instance, VkPhysicalDevice) override
	{
		if (instance == VK_NULL_HANDLE)
		{
			return VK_NULL_HANDLE;
		}
		VkSurfaceKHR                surface{};
		VkWin32SurfaceCreateInfoKHR info{VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR};
		info.hinstance = hinstance;
		info.hwnd      = hwnd;
		VK_CHECK(vkCreateWin32SurfaceKHR(instance, &info, nullptr, &surface));
		return surface;
	}

	// ewv pumps the window's messages itself (src/vks.rs).
	void process_events() override
	{}

	bool should_close() override
	{
		return closed;
	}

	void close() override
	{
		closed = true;
	}

	float get_dpi_factor() const override
	{
		return scale;
	}

	float get_content_scale_factor() const override
	{
		return 1.0f;
	}

	std::vector<const char *> get_required_surface_extensions() const override
	{
		return {VK_KHR_WIN32_SURFACE_EXTENSION_NAME};
	}

  private:
	HINSTANCE hinstance;
	HWND      hwnd;
	float     scale;
	bool      closed{false};
};

class EwvPlatform final : public vkb::Platform
{
  public:
	EwvPlatform(const vkb::PlatformContext &context, HINSTANCE hinstance, HWND hwnd, float scale, uint32_t width, uint32_t height) :
	    Platform{context}, hinstance(hinstance), hwnd(hwnd), scale(scale), extent{width, height}
	{}

  protected:
	void create_window(const vkb::Window::Properties &properties) override
	{
		// The buffer's window, not a command-line option, decides the size.
		auto sized   = properties;
		sized.extent = extent;
		window       = std::make_unique<EwvWindow>(sized, hinstance, hwnd, scale);
	}

  private:
	HINSTANCE           hinstance;
	HWND                hwnd;
	float               scale;
	vkb::Window::Extent extent;
};

std::unique_ptr<EwvContext>  g_context;
std::unique_ptr<EwvPlatform> g_platform;

void set_error(char *err, size_t len, const std::string &message)
{
	if (err && len)
	{
		std::snprintf(err, len, "%s", message.c_str());
	}
}
}        // namespace

extern "C" int ewv_vks_running(void)
{
	return g_platform ? 1 : 0;
}

extern "C" int ewv_vks_start(void *hinstance, void *hwnd, const char *sample_id, const char *root,
                             uint32_t width, uint32_t height, float scale, char *err, size_t err_len)
{
	if (g_platform)
	{
		set_error(err, err_len, "Another Vulkan sample is already running; kill its buffer first.");
		return 1;
	}
	if (!apps::get_sample(sample_id))
	{
		set_error(err, err_len, std::string("Unknown Vulkan sample: ") + sample_id);
		return 1;
	}
	try
	{
		g_context = std::make_unique<EwvContext>(std::vector<std::string>{"sample", sample_id}, root);
		vkb::filesystem::init_with_context(*g_context);
		g_platform = std::make_unique<EwvPlatform>(*g_context, static_cast<HINSTANCE>(hinstance),
		                                           static_cast<HWND>(hwnd), scale, width, height);

		auto code = g_platform->initialize(plugins::get_all());
		if (code != vkb::ExitCode::Success)
		{
			std::string reason = g_platform->get_last_error();
			ewv_vks_stop();
			set_error(err, err_len, reason.empty() ? "The sample could not be started." : reason);
			return 1;
		}
	}
	catch (const std::exception &e)
	{
		std::string reason = e.what();
		ewv_vks_stop();
		set_error(err, err_len, reason);
		return 1;
	}
	return 0;
}

extern "C" int ewv_vks_frame(char *err, size_t err_len)
{
	if (!g_platform)
	{
		set_error(err, err_len, "No Vulkan sample is running.");
		return 1;
	}
	vkb::ExitCode code = vkb::ExitCode::FatalError;
	std::string   reason;
	try
	{
		code   = g_platform->main_loop_frame();
		reason = g_platform->get_last_error();
	}
	catch (const std::exception &e)
	{
		reason = e.what();
	}
	catch (...)
	{
		reason = "Unknown error in the sample.";
	}
	if (code == vkb::ExitCode::Success)
	{
		return 0;
	}
	if (reason.empty())
	{
		reason = code == vkb::ExitCode::Close ? "The sample finished." : "The sample stopped (see the log).";
	}
	set_error(err, err_len, reason);
	return 1;
}

extern "C" void ewv_vks_resize(uint32_t width, uint32_t height)
{
	if (g_platform)
	{
		try
		{
			g_platform->resize(width, height);
		}
		catch (...)
		{}
	}
}

extern "C" void ewv_vks_mouse(int action, float x, float y)
{
	if (!g_platform)
	{
		return;
	}
	const vkb::MouseAction actions[] = {vkb::MouseAction::Down, vkb::MouseAction::Up, vkb::MouseAction::Move};
	if (action < 0 || action > 2)
	{
		return;
	}
	try
	{
		g_platform->input_event(vkb::MouseButtonInputEvent{vkb::MouseButton::Left, actions[action], x, y});
	}
	catch (...)
	{}
}

extern "C" void ewv_vks_stop(void)
{
	if (g_platform)
	{
		try
		{
			g_platform->terminate(vkb::ExitCode::Success);
		}
		catch (...)
		{}
	}
	g_platform.reset();
	g_context.reset();
}
