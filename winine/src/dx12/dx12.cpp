#include "dx12.h"

#include <thread>

namespace winine::dx12
{
// ---------------------------------------------------------------------------
// Gfx
// ---------------------------------------------------------------------------

static void pick_device(IDXGIFactory6 *factory, bool need_dxr, ComPtr<ID3D12Device> &device, std::string &name)
{
	std::string without_dxr;
	for (UINT index = 0;; ++index)
	{
		ComPtr<IDXGIAdapter1> adapter;
		if (FAILED(factory->EnumAdapterByGpuPreference(index, DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,
		                                               IID_PPV_ARGS(&adapter))))
		{
			break;
		}
		DXGI_ADAPTER_DESC1 desc{};
		adapter->GetDesc1(&desc);
		if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)
		{
			continue;        // the WARP software rasterizer
		}
		std::string           adapter_name = narrow(desc.Description);
		ComPtr<ID3D12Device> candidate;
		if (FAILED(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_12_0, IID_PPV_ARGS(&candidate))))
		{
			continue;
		}
		if (need_dxr)
		{
			D3D12_FEATURE_DATA_D3D12_OPTIONS5 options{};
			bool supported = SUCCEEDED(candidate->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS5, &options, sizeof options)) &&
			                 options.RaytracingTier >= D3D12_RAYTRACING_TIER_1_0;
			if (!supported)
			{
				without_dxr += (without_dxr.empty() ? "" : ", ") + adapter_name;
				continue;
			}
		}
		device = candidate;
		name   = adapter_name;
		return;
	}
	if (need_dxr && !without_dxr.empty())
	{
		throw std::runtime_error("DirectX Raytracing is not supported by this machine's GPU (" + without_dxr + ")");
	}
	throw std::runtime_error("no Direct3D 12 GPU found on this machine");
}

Gfx::Gfx(HWND hwnd, bool need_dxr)
{
	ComPtr<IDXGIFactory6> factory;
	check(CreateDXGIFactory2(0, IID_PPV_ARGS(&factory)), "CreateDXGIFactory2");
	pick_device(factory.Get(), need_dxr, device, adapter_name);

	D3D12_COMMAND_QUEUE_DESC queue_desc{};
	queue_desc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
	check(device->CreateCommandQueue(&queue_desc, IID_PPV_ARGS(&queue)), "CreateCommandQueue");
	check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&allocator)), "CreateCommandAllocator");
	check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(), nullptr, IID_PPV_ARGS(&list)),
	      "CreateCommandList");
	list->Close();        // created recording; begin_frame resets it

	DXGI_SWAP_CHAIN_DESC1 sc{};
	sc.Width       = 1;
	sc.Height      = 1;
	sc.Format      = BACK_BUFFER_FORMAT;
	sc.SampleDesc  = {1, 0};
	sc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
	sc.BufferCount = BACK_BUFFER_COUNT;
	sc.SwapEffect  = DXGI_SWAP_EFFECT_FLIP_DISCARD;
	ComPtr<IDXGISwapChain1> swap_chain1;
	check(factory->CreateSwapChainForHwnd(queue.Get(), hwnd, &sc, nullptr, nullptr, &swap_chain1), "CreateSwapChainForHwnd");
	check(swap_chain1.As(&swap_chain), "IDXGISwapChain3");
	factory->MakeWindowAssociation(hwnd, DXGI_MWA_NO_ALT_ENTER);

	D3D12_DESCRIPTOR_HEAP_DESC heap{};
	heap.Type           = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
	heap.NumDescriptors = BACK_BUFFER_COUNT;
	check(device->CreateDescriptorHeap(&heap, IID_PPV_ARGS(&rtv_heap)), "CreateDescriptorHeap");
	rtv_size = device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);

	check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)), "CreateFence");
	fence_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
	create_back_buffer_views();
}

Gfx::~Gfx()
{
	if (fence_event)
	{
		CloseHandle(fence_event);
	}
}

void Gfx::create_back_buffer_views()
{
	for (UINT i = 0; i < BACK_BUFFER_COUNT; ++i)
	{
		ComPtr<ID3D12Resource> buffer;
		check(swap_chain->GetBuffer(i, IID_PPV_ARGS(&buffer)), "GetBuffer");
		device->CreateRenderTargetView(buffer.Get(), nullptr, rtv(i));
		back_buffers.push_back(buffer);
	}
}

D3D12_CPU_DESCRIPTOR_HANDLE Gfx::rtv(size_t index) const
{
	D3D12_CPU_DESCRIPTOR_HANDLE start = rtv_heap->GetCPUDescriptorHandleForHeapStart();
	start.ptr += index * rtv_size;
	return start;
}

void Gfx::wait_idle()
{
	++fence_value;
	check(queue->Signal(fence.Get(), fence_value), "Signal");
	if (fence->GetCompletedValue() < fence_value)
	{
		check(fence->SetEventOnCompletion(fence_value, fence_event), "SetEventOnCompletion");
		WaitForSingleObject(fence_event, INFINITE);
	}
}

void Gfx::resize(uint32_t w, uint32_t h)
{
	wait_idle();
	back_buffers.clear();        // ResizeBuffers needs them released
	check(swap_chain->ResizeBuffers(BACK_BUFFER_COUNT, w, h, BACK_BUFFER_FORMAT, 0), "ResizeBuffers");
	width  = w;
	height = h;
	create_back_buffer_views();
}

void Gfx::begin_commands()
{
	check(allocator->Reset(), "CommandAllocator::Reset");
	check(list->Reset(allocator.Get(), nullptr), "CommandList::Reset");
}

void Gfx::submit_and_wait()
{
	check(list->Close(), "CommandList::Close");
	ID3D12CommandList *lists[] = {list.Get()};
	queue->ExecuteCommandLists(1, lists);
	wait_idle();
}

size_t Gfx::begin_frame()
{
	begin_commands();
	return swap_chain->GetCurrentBackBufferIndex();
}

void Gfx::end_frame()
{
	check(list->Close(), "CommandList::Close");
	ID3D12CommandList *lists[] = {list.Get()};
	queue->ExecuteCommandLists(1, lists);
	HRESULT hr = swap_chain->Present(1, 0);
	check(hr, "Present");
	occluded = hr == DXGI_STATUS_OCCLUDED;
	wait_idle();
}

void Gfx::full_viewport(D3D12_VIEWPORT &viewport, D3D12_RECT &scissor) const
{
	viewport = {0.0f, 0.0f, static_cast<float>(width), static_cast<float>(height), 0.0f, 1.0f};
	scissor  = {0, 0, static_cast<LONG>(width), static_cast<LONG>(height)};
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

D3D12_RESOURCE_BARRIER transition(ID3D12Resource *resource, D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after)
{
	D3D12_RESOURCE_BARRIER barrier{};
	barrier.Type                   = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
	barrier.Transition.pResource   = resource;
	barrier.Transition.StateBefore = before;
	barrier.Transition.StateAfter  = after;
	barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
	return barrier;
}

ComPtr<ID3D12Resource> create_buffer(ID3D12Device *device, uint64_t size, D3D12_HEAP_TYPE heap,
                                     D3D12_RESOURCE_FLAGS flags, D3D12_RESOURCE_STATES state)
{
	D3D12_HEAP_PROPERTIES props{};
	props.Type = heap;
	D3D12_RESOURCE_DESC desc{};
	desc.Dimension        = D3D12_RESOURCE_DIMENSION_BUFFER;
	desc.Width            = size ? size : 1;
	desc.Height           = 1;
	desc.DepthOrArraySize = 1;
	desc.MipLevels        = 1;
	desc.SampleDesc       = {1, 0};
	desc.Layout           = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
	desc.Flags            = flags;
	ComPtr<ID3D12Resource> resource;
	check(device->CreateCommittedResource(&props, D3D12_HEAP_FLAG_NONE, &desc, state, nullptr, IID_PPV_ARGS(&resource)),
	      "CreateCommittedResource (buffer)");
	return resource;
}

ComPtr<ID3D12Resource> create_upload_buffer(ID3D12Device *device, const void *data, size_t bytes)
{
	auto  buffer = create_buffer(device, bytes, D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_FLAG_NONE,
	                             D3D12_RESOURCE_STATE_GENERIC_READ);
	void *mapped = nullptr;
	check(buffer->Map(0, nullptr, &mapped), "Map");
	std::memcpy(mapped, data, bytes);
	buffer->Unmap(0, nullptr);
	return buffer;
}

ComPtr<ID3D12RootSignature> create_root_signature(ID3D12Device *device, const D3D12_ROOT_SIGNATURE_DESC &desc)
{
	ComPtr<ID3DBlob> blob, errors;
	HRESULT hr = D3D12SerializeRootSignature(&desc, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &errors);
	if (FAILED(hr))
	{
		std::string text = errors ? std::string(static_cast<const char *>(errors->GetBufferPointer()), errors->GetBufferSize()) : "";
		throw HResultError(hr, "root signature " + text);
	}
	ComPtr<ID3D12RootSignature> signature;
	check(device->CreateRootSignature(0, blob->GetBufferPointer(), blob->GetBufferSize(), IID_PPV_ARGS(&signature)),
	      "CreateRootSignature");
	return signature;
}

// ---------------------------------------------------------------------------
// Render thread
// ---------------------------------------------------------------------------

static LRESULT CALLBACK view_procedure(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam)
{
	switch (msg)
	{
		case WM_ERASEBKGND:        // the swap chain covers the whole window
			return 1;
		case WM_DESTROY:        // by us on close, or by Windows with the frame
			PostQuitMessage(0);
			return 0;
		default:
			return DefWindowProcW(hwnd, msg, wparam, lparam);
	}
}

static void render_loop(bool raytracing, HWND hwnd, Commands &commands, ViewState &state)
{
	Gfx                   gfx(hwnd, raytracing);
	std::unique_ptr<Demo> demo = raytracing ? make_raytracing(gfx) : make_triangle(gfx);
	state.set_status("running on " + gfx.adapter_name);

	bool                          visible = false;
	std::pair<uint32_t, uint32_t> size{1, 1};
	for (;;)
	{
		while (auto command = commands.try_receive())
		{
			if (!apply_command(hwnd, *command, size, visible))
			{
				gfx.wait_idle();
				return;
			}
		}
		if (!pump_view_messages())
		{
			gfx.wait_idle();
			return;
		}
		bool idle = !visible;
		if (visible)
		{
			if (size.first != gfx.width || size.second != gfx.height)
			{
				gfx.resize(size.first, size.second);
				demo->resized(gfx);
			}
			demo->render(gfx);
			state.frames++;
			idle = gfx.occluded;        // Present does not wait while covered
		}
		if (idle)
		{
			MsgWaitForMultipleObjects(0, nullptr, FALSE, 30, QS_ALLINPUT);
		}
	}
}

std::unique_ptr<ViewHandle> open(const std::string &demo, HWND parent)
{
	bool raytracing;
	if (demo == "triangle")
	{
		raytracing = false;
	}
	else if (demo == "raytracing")
	{
		raytracing = true;
	}
	else
	{
		throw std::runtime_error("unknown dx12 demo \"" + demo + "\" (triangle, raytracing)");
	}
	auto view = std::make_unique<ViewHandle>();
	view->id  = new_view_id();
	std::thread([raytracing, parent, commands = view->commands, state = view->state] {
		HWND hwnd = nullptr;
		try
		{
			hwnd = create_view_window(L"WinineDx12View", view_procedure, parent, true);
			render_loop(raytracing, hwnd, *commands, *state);
			state->set_status("closed");
		}
		catch (const std::exception &e)
		{
			state->set_status(std::string("error: ") + e.what());
		}
		if (hwnd)
		{
			DestroyWindow(hwnd);        // fails harmlessly if it went with its frame
		}
		commands->finish();
	}).detach();
	return view;
}
}        // namespace winine::dx12
