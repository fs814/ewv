//! Direct3D 12 demo views hosted in Emacs frames (see README.md here).
//!
//! Each view is a child window of an Emacs frame with its own render thread.
//! The thread creates the window, owns every Direct3D object, pumps the
//! window's messages and renders with vsync, so nothing here ever runs a frame
//! on the Lisp thread or the frame's input thread. The Lisp side only holds a
//! `DxView` handle and sends it commands (place, show, reparent, close).
//!
//! The window is `WS_DISABLED`: mouse input falls through to the Emacs frame,
//! so clicking the demo selects the Emacs window showing it, like any buffer.

use anyhow::{Result, anyhow};
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Once, mpsc};
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Direct3D::*;
use windows::Win32::Graphics::Direct3D12::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Graphics::Dxgi::*;
use windows::Win32::System::Threading::{CreateEventW, INFINITE, WaitForSingleObject};
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{Interface, w};

mod raytracing;
mod triangle;

pub const BACK_BUFFER_COUNT: u32 = 2;
pub const BACK_BUFFER_FORMAT: DXGI_FORMAT = DXGI_FORMAT_R8G8B8A8_UNORM;

/// A demo renderer. It is created, used and dropped on the view's render thread.
pub trait Demo {
    /// Record and submit one frame. Call `gfx.begin_frame()` first and
    /// `gfx.end_frame()` last.
    fn render(&mut self, gfx: &mut Gfx) -> Result<()>;
    /// The swap chain was resized to `gfx.width` x `gfx.height`.
    fn resized(&mut self, _gfx: &mut Gfx) -> Result<()> {
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Lisp-thread handle
// ---------------------------------------------------------------------------

enum Cmd {
    Bounds(RECT),
    Visible(bool),
    /// New parent window, and where to report that the move is done.
    Parent(isize, mpsc::Sender<()>),
    Close,
}

struct Shared {
    status: Mutex<String>,
    frames: AtomicU64,
}

impl Shared {
    fn set_status(&self, status: impl Into<String>) {
        *self.status.lock().unwrap() = status.into();
    }
}

pub struct DxView {
    pub id: i64,
    tx: mpsc::Sender<Cmd>,
    shared: Arc<Shared>,
}

#[derive(Clone, Copy)]
enum DemoKind {
    Triangle,
    RayTracing,
}

impl DxView {
    pub fn open(demo: &str, parent: HWND) -> Result<DxView> {
        let kind = match demo {
            "triangle" => DemoKind::Triangle,
            "raytracing" => DemoKind::RayTracing,
            other => return Err(anyhow!("unknown dx12 demo {other:?} (triangle, raytracing)")),
        };
        static NEXT_ID: AtomicI64 = AtomicI64::new(1);
        let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);

        let (tx, rx) = mpsc::channel();
        let shared = Arc::new(Shared {
            status: Mutex::new("starting".into()),
            frames: AtomicU64::new(0),
        });
        let thread_shared = shared.clone();
        let parent = parent.0 as isize; // HWND is not Send
        std::thread::Builder::new()
            .name(format!("ewv-dx12-{demo}-{id}"))
            .spawn(move || {
                match run_view(kind, parent, rx, &thread_shared) {
                    Ok(()) => thread_shared.set_status("closed"),
                    Err(e) => thread_shared.set_status(format!("error: {e:#}")),
                }
            })?;
        Ok(DxView { id, tx, shared })
    }

    // A send only fails when the render thread has already exited; the status
    // then says why, so there is nothing more to report here.
    pub fn resize(&self, bounds: RECT) {
        let _ = self.tx.send(Cmd::Bounds(bounds));
    }
    pub fn set_visible(&self, visible: bool) {
        let _ = self.tx.send(Cmd::Visible(visible));
    }
    /// Move the view to another frame. Unlike the other commands this waits
    /// for the render thread to do it (which takes at most one frame): the
    /// caller may be about to delete the old frame, and Windows destroys a
    /// frame's child windows with it.
    pub fn reparent(&self, parent: HWND) {
        let (done_tx, done_rx) = mpsc::channel();
        if self.tx.send(Cmd::Parent(parent.0 as isize, done_tx)).is_ok() {
            let _ = done_rx.recv_timeout(std::time::Duration::from_secs(2));
        }
    }
    pub fn close(&self) {
        let _ = self.tx.send(Cmd::Close);
    }
    pub fn status(&self) -> String {
        self.shared.status.lock().unwrap().clone()
    }
    pub fn frames(&self) -> u64 {
        self.shared.frames.load(Ordering::Relaxed)
    }
}

// ---------------------------------------------------------------------------
// Render thread
// ---------------------------------------------------------------------------

unsafe extern "system" fn view_wnd_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        // The swap chain covers the whole window.
        WM_ERASEBKGND => LRESULT(1),
        // Destroyed by us on close, or by Windows with the Emacs frame: either
        // way the render loop must stop.
        WM_DESTROY => {
            unsafe { PostQuitMessage(0) };
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

fn create_view_window(parent: HWND) -> Result<HWND> {
    let class_name = w!("EwvDx12View");
    let hinstance = crate::get_dll_hinstance();
    static REGISTER: Once = Once::new();
    REGISTER.call_once(|| {
        let class = WNDCLASSW {
            lpfnWndProc: Some(view_wnd_proc),
            hInstance: hinstance,
            lpszClassName: class_name,
            ..Default::default()
        };
        unsafe { RegisterClassW(&class) };
    });
    let hwnd = unsafe {
        CreateWindowExW(
            WS_EX_NOPARENTNOTIFY,
            class_name,
            w!("ewv dx12 view"),
            WS_CHILD | WS_DISABLED | WS_CLIPSIBLINGS,
            0,
            0,
            1,
            1,
            Some(parent),
            None,
            Some(hinstance),
            None,
        )?
    };
    Ok(hwnd)
}

fn run_view(
    kind: DemoKind,
    parent: isize,
    rx: mpsc::Receiver<Cmd>,
    shared: &Shared,
) -> Result<()> {
    let hwnd = create_view_window(HWND(parent as *mut _))?;
    let result = render_loop(kind, hwnd, rx, shared);
    // No-op (an error we ignore) when the window already went with its frame.
    unsafe {
        let _ = DestroyWindow(hwnd);
    }
    result
}

fn render_loop(
    kind: DemoKind,
    hwnd: HWND,
    rx: mpsc::Receiver<Cmd>,
    shared: &Shared,
) -> Result<()> {
    let mut gfx = Gfx::new(hwnd, matches!(kind, DemoKind::RayTracing))?;
    let mut demo: Box<dyn Demo> = match kind {
        DemoKind::Triangle => Box::new(triangle::Triangle::new(&mut gfx)?),
        DemoKind::RayTracing => Box::new(raytracing::RayTracing::new(&mut gfx)?),
    };
    shared.set_status(format!("running on {}", gfx.adapter_name));

    let mut visible = false;
    let mut size = (1u32, 1u32);
    'outer: loop {
        loop {
            match rx.try_recv() {
                Ok(Cmd::Bounds(r)) => {
                    let (w, h) = ((r.right - r.left).max(1), (r.bottom - r.top).max(1));
                    size = (w as u32, h as u32);
                    unsafe {
                        SetWindowPos(hwnd, Some(HWND_TOP), r.left, r.top, w, h, SWP_NOACTIVATE)?;
                    }
                }
                Ok(Cmd::Visible(v)) => {
                    visible = v;
                    unsafe {
                        let _ = ShowWindow(hwnd, if v { SW_SHOWNA } else { SW_HIDE });
                    }
                }
                Ok(Cmd::Parent(p, done)) => {
                    let moved = unsafe { SetParent(hwnd, Some(HWND(p as *mut _))) };
                    let _ = done.send(());
                    moved?;
                }
                // Disconnected: the Lisp handle is gone.
                Ok(Cmd::Close) | Err(mpsc::TryRecvError::Disconnected) => break 'outer,
                Err(mpsc::TryRecvError::Empty) => break,
            }
        }

        let mut msg = MSG::default();
        while unsafe { PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE) }.as_bool() {
            if msg.message == WM_QUIT {
                break 'outer;
            }
            unsafe {
                DispatchMessageW(&msg);
            }
        }

        let mut idle = !visible;
        if visible {
            if size != (gfx.width, gfx.height) {
                gfx.resize(size.0, size.1)?;
                demo.resized(&mut gfx)?;
            }
            demo.render(&mut gfx)?;
            shared.frames.fetch_add(1, Ordering::Relaxed);
            // Present does not wait for vsync while the window is covered.
            idle = gfx.occluded;
        }
        if idle {
            unsafe {
                MsgWaitForMultipleObjects(None, false, 30, QS_ALLINPUT);
            }
        }
    }
    gfx.wait_idle()?;
    Ok(())
}

// ---------------------------------------------------------------------------
// What both demos need: device, queue, swap chain, one command list, a fence
// ---------------------------------------------------------------------------

pub struct Gfx {
    pub device: ID3D12Device,
    pub queue: ID3D12CommandQueue,
    pub allocator: ID3D12CommandAllocator,
    pub list: ID3D12GraphicsCommandList,
    pub swap_chain: IDXGISwapChain3,
    pub back_buffers: Vec<ID3D12Resource>,
    rtv_heap: ID3D12DescriptorHeap,
    rtv_size: usize,
    fence: ID3D12Fence,
    fence_value: u64,
    fence_event: HANDLE,
    pub width: u32,
    pub height: u32,
    pub adapter_name: String,
    /// The last Present reported the window as fully covered.
    pub occluded: bool,
}

impl Gfx {
    /// Create a device on the fastest GPU (the discrete one on a dual-GPU
    /// machine); with `need_dxr`, on the fastest GPU that supports DirectX
    /// Raytracing.
    fn new(hwnd: HWND, need_dxr: bool) -> Result<Gfx> {
        unsafe {
            let factory: IDXGIFactory6 = CreateDXGIFactory2(DXGI_CREATE_FACTORY_FLAGS(0))?;
            let (device, adapter_name) = pick_device(&factory, need_dxr)?;

            let queue: ID3D12CommandQueue = device.CreateCommandQueue(&D3D12_COMMAND_QUEUE_DESC {
                Type: D3D12_COMMAND_LIST_TYPE_DIRECT,
                ..Default::default()
            })?;
            let allocator: ID3D12CommandAllocator =
                device.CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT)?;
            let list: ID3D12GraphicsCommandList =
                device.CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, &allocator, None)?;
            list.Close()?; // created recording; begin_frame resets it

            let swap_chain: IDXGISwapChain3 = factory
                .CreateSwapChainForHwnd(
                    &queue,
                    hwnd,
                    &DXGI_SWAP_CHAIN_DESC1 {
                        Width: 1,
                        Height: 1,
                        Format: BACK_BUFFER_FORMAT,
                        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                        BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
                        BufferCount: BACK_BUFFER_COUNT,
                        SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD,
                        ..Default::default()
                    },
                    None,
                    None,
                )?
                .cast()?;
            factory.MakeWindowAssociation(hwnd, DXGI_MWA_NO_ALT_ENTER)?;

            let rtv_heap: ID3D12DescriptorHeap =
                device.CreateDescriptorHeap(&D3D12_DESCRIPTOR_HEAP_DESC {
                    Type: D3D12_DESCRIPTOR_HEAP_TYPE_RTV,
                    NumDescriptors: BACK_BUFFER_COUNT,
                    ..Default::default()
                })?;
            let rtv_size =
                device.GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV) as usize;

            let fence: ID3D12Fence = device.CreateFence(0, D3D12_FENCE_FLAG_NONE)?;
            let fence_event = CreateEventW(None, false, false, None)?;

            let mut gfx = Gfx {
                device,
                queue,
                allocator,
                list,
                swap_chain,
                back_buffers: Vec::new(),
                rtv_heap,
                rtv_size,
                fence,
                fence_value: 0,
                fence_event,
                width: 1,
                height: 1,
                adapter_name,
                occluded: false,
            };
            gfx.create_back_buffer_views()?;
            Ok(gfx)
        }
    }

    fn create_back_buffer_views(&mut self) -> Result<()> {
        for i in 0..BACK_BUFFER_COUNT {
            unsafe {
                let buffer: ID3D12Resource = self.swap_chain.GetBuffer(i)?;
                self.device
                    .CreateRenderTargetView(&buffer, None, self.rtv(i as usize));
                self.back_buffers.push(buffer);
            }
        }
        Ok(())
    }

    pub fn rtv(&self, index: usize) -> D3D12_CPU_DESCRIPTOR_HANDLE {
        let start = unsafe { self.rtv_heap.GetCPUDescriptorHandleForHeapStart() };
        D3D12_CPU_DESCRIPTOR_HANDLE {
            ptr: start.ptr + index * self.rtv_size,
        }
    }

    /// Block until the GPU has finished everything submitted so far.
    pub fn wait_idle(&mut self) -> Result<()> {
        self.fence_value += 1;
        unsafe {
            self.queue.Signal(&self.fence, self.fence_value)?;
            if self.fence.GetCompletedValue() < self.fence_value {
                self.fence
                    .SetEventOnCompletion(self.fence_value, self.fence_event)?;
                WaitForSingleObject(self.fence_event, INFINITE);
            }
        }
        Ok(())
    }

    fn resize(&mut self, width: u32, height: u32) -> Result<()> {
        self.wait_idle()?;
        self.back_buffers.clear(); // ResizeBuffers needs them released
        unsafe {
            self.swap_chain.ResizeBuffers(
                BACK_BUFFER_COUNT,
                width,
                height,
                BACK_BUFFER_FORMAT,
                DXGI_SWAP_CHAIN_FLAG(0),
            )?;
        }
        self.width = width;
        self.height = height;
        self.create_back_buffer_views()
    }

    /// Start recording into `self.list`.
    pub fn begin_commands(&mut self) -> Result<()> {
        unsafe {
            self.allocator.Reset()?;
            self.list.Reset(&self.allocator, None)?;
        }
        Ok(())
    }

    /// Submit `self.list` and wait for it (setup work such as building
    /// acceleration structures).
    pub fn submit_and_wait(&mut self) -> Result<()> {
        unsafe {
            self.list.Close()?;
            self.queue
                .ExecuteCommandLists(&[Some(self.list.cast::<ID3D12CommandList>()?)]);
        }
        self.wait_idle()
    }

    /// Start a frame; returns the index of the back buffer to draw into.
    pub fn begin_frame(&mut self) -> Result<usize> {
        self.begin_commands()?;
        Ok(unsafe { self.swap_chain.GetCurrentBackBufferIndex() } as usize)
    }

    /// Submit the frame, present it with vsync and wait for the GPU, so the
    /// single command allocator can be reset for the next frame.
    pub fn end_frame(&mut self) -> Result<()> {
        unsafe {
            self.list.Close()?;
            self.queue
                .ExecuteCommandLists(&[Some(self.list.cast::<ID3D12CommandList>()?)]);
            let hr = self.swap_chain.Present(1, DXGI_PRESENT(0));
            hr.ok()?;
            self.occluded = hr == DXGI_STATUS_OCCLUDED;
        }
        self.wait_idle()
    }

    pub fn full_viewport(&self) -> (D3D12_VIEWPORT, RECT) {
        (
            D3D12_VIEWPORT {
                TopLeftX: 0.0,
                TopLeftY: 0.0,
                Width: self.width as f32,
                Height: self.height as f32,
                MinDepth: 0.0,
                MaxDepth: 1.0,
            },
            RECT {
                left: 0,
                top: 0,
                right: self.width as i32,
                bottom: self.height as i32,
            },
        )
    }
}

impl Drop for Gfx {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.fence_event);
        }
    }
}

fn pick_device(factory: &IDXGIFactory6, need_dxr: bool) -> Result<(ID3D12Device, String)> {
    let mut without_dxr = Vec::new();
    for index in 0.. {
        let Ok(adapter) = (unsafe {
            factory.EnumAdapterByGpuPreference::<IDXGIAdapter1>(
                index,
                DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,
            )
        }) else {
            break;
        };
        let desc = unsafe { adapter.GetDesc1()? };
        if desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE.0 as u32 != 0 {
            continue; // the WARP software rasterizer
        }
        let name = String::from_utf16_lossy(&desc.Description)
            .trim_end_matches('\0')
            .to_string();

        let mut device: Option<ID3D12Device> = None;
        if unsafe { D3D12CreateDevice(&adapter, D3D_FEATURE_LEVEL_12_0, &mut device) }.is_err() {
            continue;
        }
        let Some(device) = device else { continue };

        if need_dxr {
            let mut options = D3D12_FEATURE_DATA_D3D12_OPTIONS5::default();
            let supported = unsafe {
                device.CheckFeatureSupport(
                    D3D12_FEATURE_D3D12_OPTIONS5,
                    &mut options as *mut _ as *mut _,
                    size_of::<D3D12_FEATURE_DATA_D3D12_OPTIONS5>() as u32,
                )
            }
            .is_ok()
                && options.RaytracingTier.0 >= D3D12_RAYTRACING_TIER_1_0.0;
            if !supported {
                without_dxr.push(name);
                continue;
            }
        }
        return Ok((device, name));
    }
    if need_dxr && !without_dxr.is_empty() {
        Err(anyhow!(
            "DirectX Raytracing is not supported by this machine's GPU ({})",
            without_dxr.join(", ")
        ))
    } else {
        Err(anyhow!("no Direct3D 12 GPU found on this machine"))
    }
}

// ---------------------------------------------------------------------------
// Small helpers shared by the demos
// ---------------------------------------------------------------------------

/// A transition barrier that borrows `resource` (no reference is taken, so
/// nothing needs releasing afterwards).
pub fn transition(
    resource: &ID3D12Resource,
    before: D3D12_RESOURCE_STATES,
    after: D3D12_RESOURCE_STATES,
) -> D3D12_RESOURCE_BARRIER {
    D3D12_RESOURCE_BARRIER {
        Type: D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
        Flags: D3D12_RESOURCE_BARRIER_FLAG_NONE,
        Anonymous: D3D12_RESOURCE_BARRIER_0 {
            Transition: std::mem::ManuallyDrop::new(D3D12_RESOURCE_TRANSITION_BARRIER {
                pResource: unsafe { std::mem::transmute_copy(resource) },
                StateBefore: before,
                StateAfter: after,
                Subresource: D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
            }),
        },
    }
}

pub fn create_buffer(
    device: &ID3D12Device,
    size: u64,
    heap: D3D12_HEAP_TYPE,
    flags: D3D12_RESOURCE_FLAGS,
    state: D3D12_RESOURCE_STATES,
) -> Result<ID3D12Resource> {
    let mut resource: Option<ID3D12Resource> = None;
    unsafe {
        device.CreateCommittedResource(
            &D3D12_HEAP_PROPERTIES {
                Type: heap,
                ..Default::default()
            },
            D3D12_HEAP_FLAG_NONE,
            &D3D12_RESOURCE_DESC {
                Dimension: D3D12_RESOURCE_DIMENSION_BUFFER,
                Width: size.max(1),
                Height: 1,
                DepthOrArraySize: 1,
                MipLevels: 1,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Layout: D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
                Flags: flags,
                ..Default::default()
            },
            state,
            None,
            &mut resource,
        )?;
    }
    resource.ok_or_else(|| anyhow!("CreateCommittedResource returned no buffer"))
}

/// A CPU-writable buffer holding a copy of `data`.
pub fn create_upload_buffer<T: Copy>(device: &ID3D12Device, data: &[T]) -> Result<ID3D12Resource> {
    let bytes = std::mem::size_of_val(data);
    let buffer = create_buffer(
        device,
        bytes as u64,
        D3D12_HEAP_TYPE_UPLOAD,
        D3D12_RESOURCE_FLAG_NONE,
        D3D12_RESOURCE_STATE_GENERIC_READ,
    )?;
    unsafe {
        let mut mapped = std::ptr::null_mut();
        buffer.Map(0, None, Some(&mut mapped))?;
        std::ptr::copy_nonoverlapping(data.as_ptr() as *const u8, mapped as *mut u8, bytes);
        buffer.Unmap(0, None);
    }
    Ok(buffer)
}

/// The text of a compiler or serializer message blob.
pub fn blob_text(blob: &Option<ID3DBlob>) -> String {
    match blob {
        Some(blob) => unsafe {
            let bytes = std::slice::from_raw_parts(
                blob.GetBufferPointer() as *const u8,
                blob.GetBufferSize(),
            );
            String::from_utf8_lossy(bytes).trim_end_matches('\0').trim().to_string()
        },
        None => String::new(),
    }
}

pub fn create_root_signature(
    device: &ID3D12Device,
    desc: &D3D12_ROOT_SIGNATURE_DESC,
) -> Result<ID3D12RootSignature> {
    let mut blob = None;
    let mut errors = None;
    unsafe {
        D3D12SerializeRootSignature(desc, D3D_ROOT_SIGNATURE_VERSION_1, &mut blob, Some(&mut errors))
            .map_err(|e| anyhow!("root signature: {e} {}", blob_text(&errors)))?;
        let blob = blob.ok_or_else(|| anyhow!("root signature: no blob"))?;
        Ok(device.CreateRootSignature(
            0,
            std::slice::from_raw_parts(blob.GetBufferPointer() as *const u8, blob.GetBufferSize()),
        )?)
    }
}
