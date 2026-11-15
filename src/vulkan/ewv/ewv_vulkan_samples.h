/*
 * ewv_vulkan_samples.h -- C interface of ewv-vulkan-samples.dll, the Khronos
 * Vulkan-Samples built for ewv (see ../README.md). ewv_native.dll loads it
 * with LoadLibrary on first use, so ewv itself builds and runs without it.
 *
 * The Windows counterpart of appine's appine_vulkan_samples.h: the same calls,
 * with an HWND where appine passes a CAMetalLayer.
 *
 * One sample runs at a time: the framework keeps global state. Call
 * everything from one thread (ewv uses the view's render thread, which also
 * owns the window).
 */
#ifndef EWV_VULKAN_SAMPLES_H
#define EWV_VULKAN_SAMPLES_H

#include <stddef.h>
#include <stdint.h>

#ifdef EWV_VKS_BUILDING
#	define EWV_VKS_API __declspec(dllexport)
#else
#	define EWV_VKS_API __declspec(dllimport)
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Start SAMPLE_ID (e.g. "hello_triangle") drawing into HWND (a window of
 * module HINSTANCE, WIDTH x HEIGHT pixels, SCALE = DPI / 96). ROOT is the
 * Vulkan-Samples folder holding assets/ and shaders/, UTF-8. Returns 0, or
 * nonzero with a message in ERR. */
EWV_VKS_API int ewv_vks_start(void *hinstance, void *hwnd, const char *sample_id, const char *root,
                              uint32_t width, uint32_t height, float scale, char *err, size_t err_len);

/* Render one frame. Returns 0 to continue; nonzero when the sample ended or
 * failed, with the reason in ERR. After that only ewv_vks_stop is valid. */
EWV_VKS_API int ewv_vks_frame(char *err, size_t err_len);

/* The window's client size changed. */
EWV_VKS_API void ewv_vks_resize(uint32_t width, uint32_t height);

/* Left mouse button. ACTION: 0 down, 1 up, 2 move. Pixels, origin top-left. */
EWV_VKS_API void ewv_vks_mouse(int action, float x, float y);

/* Stop the running sample and release Vulkan. Safe when nothing runs. */
EWV_VKS_API void ewv_vks_stop(void);

/* 1 while a sample is running. */
EWV_VKS_API int ewv_vks_running(void);

#ifdef __cplusplus
}
#endif

#endif
