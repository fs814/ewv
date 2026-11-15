// Direct3D 12 demo views hosted in Emacs frames: the C++ counterpart of ewv's
// src/dx12 (README.md there). A view is a disabled child window of the frame
// (clicks fall through and select the Emacs window) with a render thread that
// owns every Direct3D object and renders with vsync.
#pragma once

#include "../view.h"

#include <d3d12.h>
#include <dxgi1_6.h>

#include <memory>
#include <string>
#include <vector>

namespace winine::dx12
{
constexpr UINT        BACK_BUFFER_COUNT  = 2;
constexpr DXGI_FORMAT BACK_BUFFER_FORMAT = DXGI_FORMAT_R8G8B8A8_UNORM;

// Device, queue, swap chain, one command list and a fence: what both demos need.
class Gfx
{
  public:
	Gfx(HWND hwnd, bool need_dxr);
	~Gfx();

	ComPtr<ID3D12Device>              device;
	ComPtr<ID3D12CommandQueue>        queue;
	ComPtr<ID3D12CommandAllocator>    allocator;
	ComPtr<ID3D12GraphicsCommandList> list;
	ComPtr<IDXGISwapChain3>           swap_chain;
	std::vector<ComPtr<ID3D12Resource>> back_buffers;
	uint32_t    width  = 1;
	uint32_t    height = 1;
	std::string adapter_name;
	bool        occluded = false;        // the last Present found the window covered

	D3D12_CPU_DESCRIPTOR_HANDLE rtv(size_t index) const;
	void                        wait_idle();
	void                        resize(uint32_t width, uint32_t height);
	void                        begin_commands();
	void                        submit_and_wait();
	size_t                      begin_frame();        // returns the back buffer index
	void                        end_frame();          // submit, present with vsync, wait
	void                        full_viewport(D3D12_VIEWPORT &viewport, D3D12_RECT &scissor) const;

  private:
	void create_back_buffer_views();

	ComPtr<ID3D12DescriptorHeap> rtv_heap;
	size_t                       rtv_size = 0;
	ComPtr<ID3D12Fence>          fence;
	uint64_t                     fence_value = 0;
	HANDLE                       fence_event = nullptr;
};

class Demo
{
  public:
	virtual ~Demo() = default;
	virtual void render(Gfx &gfx) = 0;
	virtual void resized(Gfx &)
	{}
};

std::unique_ptr<Demo> make_triangle(Gfx &gfx);
std::unique_ptr<Demo> make_raytracing(Gfx &gfx);

// Helpers shared by the demos.
D3D12_RESOURCE_BARRIER transition(ID3D12Resource *resource, D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after);
ComPtr<ID3D12Resource> create_buffer(ID3D12Device *device, uint64_t size, D3D12_HEAP_TYPE heap,
                                     D3D12_RESOURCE_FLAGS flags, D3D12_RESOURCE_STATES state);
ComPtr<ID3D12Resource> create_upload_buffer(ID3D12Device *device, const void *data, size_t bytes);
ComPtr<ID3D12RootSignature> create_root_signature(ID3D12Device *device, const D3D12_ROOT_SIGNATURE_DESC &desc);

// Open DEMO ("triangle" or "raytracing") as a hidden child window of PARENT.
std::unique_ptr<ViewHandle> open(const std::string &demo, HWND parent);
}        // namespace winine::dx12
