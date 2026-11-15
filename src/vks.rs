//! Khronos Vulkan-Samples views hosted in Emacs frames (src/vulkan/README.md).
//!
//! The Windows counterpart of appine's backend_vulkan_samples.m. The samples
//! live in a separate library, ewv-vulkan-samples.dll (src/vulkan/build.ps1),
//! loaded here on first use, so ewv_native.dll builds and runs without it.
//!
//! Like the Direct3D 12 views (src/dx12), each view is a child window of an
//! Emacs frame with its own render thread: the thread creates the window, loads
//! the library, starts the sample, pumps the window's messages and asks the
//! sample for one frame at a time. The Lisp side only holds a `VkView` handle
//! and sends it commands. Unlike the DX12 views the window takes the left
//! mouse button (samples use drag to orbit their camera), as in appine; keys
//! still go to Emacs.

use anyhow::{Result, anyhow};
use std::ffi::{CString, c_char, c_void};
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Once, OnceLock, mpsc};
use windows::Win32::Foundation::*;
use windows::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryW};
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::KeyboardAndMouse::{ReleaseCapture, SetCapture};
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{HSTRING, PCSTR, w};

// ---------------------------------------------------------------------------
// ewv-vulkan-samples.dll (src/vulkan/ewv/ewv_vulkan_samples.h)
// ---------------------------------------------------------------------------

type StartFn = unsafe extern "C" fn(
    *mut c_void,
    *mut c_void,
    *const c_char,
    *const c_char,
    u32,
    u32,
    f32,
    *mut c_char,
    usize,
) -> i32;
type FrameFn = unsafe extern "C" fn(*mut c_char, usize) -> i32;
type ResizeFn = unsafe extern "C" fn(u32, u32);
type MouseFn = unsafe extern "C" fn(i32, f32, f32);
type StopFn = unsafe extern "C" fn();

struct Api {
    start: StartFn,
    frame: FrameFn,
    resize: ResizeFn,
    mouse: MouseFn,
    stop: StopFn,
}

/// The library, loaded once per Emacs session (it cannot be unloaded while a
/// sample may still be on the stack, and the framework keeps global state).
static API: OnceLock<std::result::Result<Api, String>> = OnceLock::new();

fn load_api(path: &str) -> Result<&'static Api> {
    let api = API.get_or_init(|| unsafe {
        let module = LoadLibraryW(&HSTRING::from(path)).map_err(|e| {
            format!("cannot load {path}: {e} (build it with src\\vulkan\\build.ps1)")
        })?;
        macro_rules! sym {
            ($name:literal) => {
                std::mem::transmute(
                    GetProcAddress(module, PCSTR(concat!($name, "\0").as_ptr()))
                        .ok_or_else(|| format!("{path} has no {}", $name))?,
                )
            };
        }
        Ok(Api {
            start: sym!("ewv_vks_start"),
            frame: sym!("ewv_vks_frame"),
            resize: sym!("ewv_vks_resize"),
            mouse: sym!("ewv_vks_mouse"),
            stop: sym!("ewv_vks_stop"),
        })
    });
    api.as_ref().map_err(|e| anyhow!("{e}"))
}

fn err_text(buf: &[u8]) -> String {
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..end]).trim().to_string()
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

pub struct VkView {
    pub id: i64,
    tx: mpsc::Sender<Cmd>,
    shared: Arc<Shared>,
    /// Disconnects when the render thread has exited (its sender is dropped).
    done: mpsc::Receiver<()>,
}

impl VkView {
    /// Open SAMPLE (e.g. "hello_triangle") from LIBRARY (the path of
    /// ewv-vulkan-samples.dll) with ROOT (the Vulkan-Samples folder holding
    /// assets\ and shaders\) as a hidden child window of PARENT. The sample
    /// starts once the view is first shown with a size.
    pub fn open(sample: &str, parent: HWND, library: &str, root: &str) -> Result<VkView> {
        static NEXT_ID: AtomicI64 = AtomicI64::new(1);
        let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);

        let (tx, rx) = mpsc::channel();
        let shared = Arc::new(Shared {
            status: Mutex::new("starting".into()),
            frames: AtomicU64::new(0),
        });
        let thread_shared = shared.clone();
        let (done_tx, done) = mpsc::channel::<()>();
        let parent = parent.0 as isize; // HWND is not Send
        let (sample, library, root) = (sample.to_string(), library.to_string(), root.to_string());
        std::thread::Builder::new()
            .name(format!("ewv-vulkan-{sample}-{id}"))
            .spawn(move || {
                let _done = done_tx; // dropped on exit: wakes `close`
                match run_view(&sample, &library, &root, parent, rx, &thread_shared) {
                    Ok(()) => thread_shared.set_status("closed"),
                    Err(e) => thread_shared.set_status(format!("error: {e:#}")),
                }
            })?;
        Ok(VkView { id, tx, shared, done })
    }

    // A send only fails when the render thread has already exited; the status
    // then says why, so there is nothing more to report here.
    pub fn resize(&self, bounds: RECT) {
        let _ = self.tx.send(Cmd::Bounds(bounds));
    }
    pub fn set_visible(&self, visible: bool) {
        let _ = self.tx.send(Cmd::Visible(visible));
    }
    /// Move the view to another frame, waiting for the render thread to do it
    /// (the caller may be about to delete the old frame, and Windows destroys a
    /// frame's child windows with it). While a sample is still starting this
    /// gives up after 2 s; the move then happens when it is done.
    pub fn reparent(&self, parent: HWND) {
        let (done_tx, done_rx) = mpsc::channel();
        if self.tx.send(Cmd::Parent(parent.0 as isize, done_tx)).is_ok() {
            let _ = done_rx.recv_timeout(std::time::Duration::from_secs(2));
        }
    }
    /// Stop the sample and wait (at most 3 s) until its render thread has
    /// released Vulkan and destroyed the window, so that a new sample can
    /// start right after, and Emacs does not exit with a sample mid-frame.
    pub fn close(&self) {
        if self.tx.send(Cmd::Close).is_ok() {
            let _ = self.done.recv_timeout(std::time::Duration::from_secs(3));
        }
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

/// The sample to forward mouse input to: set while one is running. Only the
/// render thread touches it (the window procedure runs on that thread).
static MOUSE: OnceLock<MouseFn> = OnceLock::new();
static RUNNING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn forward_mouse(action: i32, lparam: LPARAM) {
    if !RUNNING.load(Ordering::Relaxed) {
        return;
    }
    if let Some(mouse) = MOUSE.get() {
        let x = (lparam.0 & 0xffff) as i16 as f32;
        let y = ((lparam.0 >> 16) & 0xffff) as i16 as f32;
        unsafe { mouse(action, x, y) };
    }
}

unsafe extern "system" fn view_wnd_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        // The swap chain covers the whole window.
        WM_ERASEBKGND => LRESULT(1),
        // A click must not take focus from Emacs: keys keep going to it.
        WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
        WM_LBUTTONDOWN => {
            unsafe { SetCapture(hwnd) };
            forward_mouse(0, lparam);
            LRESULT(0)
        }
        WM_LBUTTONUP => {
            unsafe {
                let _ = ReleaseCapture();
            }
            forward_mouse(1, lparam);
            LRESULT(0)
        }
        WM_MOUSEMOVE => {
            forward_mouse(2, lparam);
            LRESULT(0)
        }
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
    let class_name = w!("EwvVulkanView");
    let hinstance = crate::get_dll_hinstance();
    static REGISTER: Once = Once::new();
    REGISTER.call_once(|| {
        let class = WNDCLASSW {
            lpfnWndProc: Some(view_wnd_proc),
            hInstance: hinstance,
            lpszClassName: class_name,
            hCursor: unsafe { LoadCursorW(None, IDC_ARROW) }.unwrap_or_default(),
            ..Default::default()
        };
        unsafe { RegisterClassW(&class) };
    });
    let hwnd = unsafe {
        CreateWindowExW(
            WS_EX_NOPARENTNOTIFY,
            class_name,
            w!("ewv vulkan view"),
            WS_CHILD | WS_CLIPSIBLINGS,
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
    sample: &str,
    library: &str,
    root: &str,
    parent: isize,
    rx: mpsc::Receiver<Cmd>,
    shared: &Shared,
) -> Result<()> {
    let api = load_api(library)?;
    let _ = MOUSE.set(api.mouse);
    let hwnd = create_view_window(HWND(parent as *mut _))?;
    let mut started = false;
    let result = render_loop(api, sample, root, hwnd, rx, shared, &mut started);
    RUNNING.store(false, Ordering::Relaxed);
    unsafe {
        // Only this view's own sample: a view that failed to start because
        // another one runs must leave that one alone.
        if started {
            (api.stop)();
        }
        // No-op (an error we ignore) when the window already went with its frame.
        let _ = DestroyWindow(hwnd);
    }
    result
}

fn render_loop(
    api: &Api,
    sample: &str,
    root: &str,
    hwnd: HWND,
    rx: mpsc::Receiver<Cmd>,
    shared: &Shared,
    started: &mut bool,
) -> Result<()> {
    let mut visible = false;
    let mut size = (0u32, 0u32);
    let mut drawn = (0u32, 0u32);
    let mut err = vec![0u8; 1024];
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

        // Start on first show, once the window has its real size: the
        // framework creates the swap chain at that size.
        if !*started && visible && size.0 > 1 && size.1 > 1 {
            let sample_c = CString::new(sample)?;
            let root_c = CString::new(root)?;
            let scale = unsafe { GetDpiForWindow(hwnd) }.max(96) as f32 / 96.0;
            let code = unsafe {
                (api.start)(
                    crate::get_dll_hinstance().0,
                    hwnd.0,
                    sample_c.as_ptr(),
                    root_c.as_ptr(),
                    size.0,
                    size.1,
                    scale,
                    err.as_mut_ptr() as *mut c_char,
                    err.len(),
                )
            };
            if code != 0 {
                return Err(anyhow!("{}", err_text(&err)));
            }
            *started = true;
            drawn = size;
            RUNNING.store(true, Ordering::Relaxed);
            shared.set_status(format!("running {sample}"));
        }

        if *started && visible {
            if size != drawn {
                unsafe { (api.resize)(size.0, size.1) };
                drawn = size;
            }
            // Presents with vsync, so this paces the loop.
            let code = unsafe { (api.frame)(err.as_mut_ptr() as *mut c_char, err.len()) };
            if code != 0 {
                return Err(anyhow!("{}", err_text(&err)));
            }
            shared.frames.fetch_add(1, Ordering::Relaxed);
        } else {
            unsafe {
                MsgWaitForMultipleObjects(None, false, 30, QS_ALLINPUT);
            }
        }
    }
    Ok(())
}
