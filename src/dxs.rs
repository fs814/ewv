//! Microsoft DirectX-Graphics-Samples in Emacs buffers (src/dxsamples/README.md).
//!
//! Each sample stays the Win32 program upstream wrote, built by
//! src/dxsamples/build.ps1. A view runs one: a thread starts the program
//! hidden, waits for its window, adopts it as a child window of the Emacs
//! frame (without a caption or border), and from then on places, shows and
//! moves it on the Lisp side's commands, like the Direct3D 12 views (src/dx12).
//! The sample keeps its own process, message loop and keyboard input: a
//! crash ends only that buffer's sample, and several can run at once.
//!
//! Calls on the sample's window use the asynchronous forms
//! (SWP_ASYNCWINDOWPOS, ShowWindowAsync), so a busy sample cannot stall Emacs.

use anyhow::{Result, anyhow};
use std::sync::atomic::{AtomicI64, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};
use windows::Win32::Foundation::*;
use windows::Win32::System::Threading::*;
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{HSTRING, PWSTR};

enum Cmd {
    Bounds(RECT),
    Visible(bool),
    Parent(isize, mpsc::Sender<()>),
    Close,
}

struct Shared {
    status: Mutex<String>,
    pid: AtomicU32,
}

impl Shared {
    fn set_status(&self, status: impl Into<String>) {
        *self.status.lock().unwrap() = status.into();
    }
}

pub struct DxsView {
    pub id: i64,
    tx: mpsc::Sender<Cmd>,
    shared: Arc<Shared>,
    done: mpsc::Receiver<()>,
}

impl DxsView {
    /// Start EXE (with ARGS, a command line tail, and CWD as its working
    /// folder) and embed its window in PARENT once it has one.
    pub fn open(exe: &str, args: &str, cwd: &str, parent: HWND) -> Result<DxsView> {
        static NEXT_ID: AtomicI64 = AtomicI64::new(1);
        let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = mpsc::channel();
        let (done_tx, done) = mpsc::channel::<()>();
        let shared = Arc::new(Shared { status: Mutex::new("starting".into()), pid: AtomicU32::new(0) });
        let thread_shared = shared.clone();
        let parent = parent.0 as isize;
        let (exe, args, cwd) = (exe.to_string(), args.to_string(), cwd.to_string());
        let name = std::path::Path::new(&exe)
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| exe.clone());
        std::thread::Builder::new()
            .name(format!("ewv-dxsample-{name}-{id}"))
            .spawn(move || {
                let _done = done_tx; // dropped on exit: wakes `close`
                if let Err(e) = run(&exe, &args, &cwd, &name, parent, rx, &thread_shared) {
                    thread_shared.set_status(format!("error: {e:#}"));
                }
            })?;
        Ok(DxsView { id, tx, shared, done })
    }

    pub fn resize(&self, bounds: RECT) {
        let _ = self.tx.send(Cmd::Bounds(bounds));
    }
    pub fn set_visible(&self, visible: bool) {
        let _ = self.tx.send(Cmd::Visible(visible));
    }
    /// Move the view to another frame and wait (at most 2 s) until done: the
    /// caller may be about to delete the old frame, which destroys its child
    /// windows (and so would end the sample).
    pub fn reparent(&self, parent: HWND) {
        let (done_tx, done_rx) = mpsc::channel();
        if self.tx.send(Cmd::Parent(parent.0 as isize, done_tx)).is_ok() {
            let _ = done_rx.recv_timeout(Duration::from_secs(2));
        }
    }
    /// Close the sample (WM_CLOSE, then terminate after 3 s) and wait for it.
    pub fn close(&self) {
        if self.tx.send(Cmd::Close).is_ok() {
            let _ = self.done.recv_timeout(Duration::from_secs(5));
        }
    }
    pub fn status(&self) -> String {
        self.shared.status.lock().unwrap().clone()
    }
    pub fn pid(&self) -> u32 {
        self.shared.pid.load(Ordering::Relaxed)
    }
}

/// A top-level window of process PID that looks like the sample's main
/// window (it has a caption: not an IME or other helper window).
fn find_main_window(pid: u32) -> Option<HWND> {
    struct Search {
        pid: u32,
        found: Option<HWND>,
    }
    unsafe extern "system" fn visit(hwnd: HWND, lparam: LPARAM) -> windows::core::BOOL {
        let search = unsafe { &mut *(lparam.0 as *mut Search) };
        let mut owner = 0u32;
        unsafe { GetWindowThreadProcessId(hwnd, Some(&mut owner)) };
        if owner == search.pid {
            let style = unsafe { GetWindowLongPtrW(hwnd, GWL_STYLE) } as u32;
            let has_owner = unsafe { GetWindow(hwnd, GW_OWNER) }.map(|o| !o.is_invalid()).unwrap_or(false);
            if style & WS_CAPTION.0 == WS_CAPTION.0 && !has_owner {
                search.found = Some(hwnd);
                return false.into();
            }
        }
        true.into()
    }
    let mut search = Search { pid, found: None };
    unsafe {
        let _ = EnumWindows(Some(visit), LPARAM(&mut search as *mut Search as isize));
    }
    search.found
}

/// Turn the sample's top-level window into a borderless child of PARENT.
fn adopt(hwnd: HWND, parent: HWND) {
    unsafe {
        let style = GetWindowLongPtrW(hwnd, GWL_STYLE) as u32;
        let frame = WS_POPUP.0 | WS_CAPTION.0 | WS_THICKFRAME.0 | WS_SYSMENU.0 | WS_MINIMIZEBOX.0 | WS_MAXIMIZEBOX.0;
        SetWindowLongPtrW(hwnd, GWL_STYLE, ((style & !frame) | WS_CHILD.0 | WS_CLIPSIBLINGS.0) as isize);
        let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE) as u32;
        let ex_frame = WS_EX_APPWINDOW.0 | WS_EX_WINDOWEDGE.0 | WS_EX_CLIENTEDGE.0 | WS_EX_DLGMODALFRAME.0;
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, (ex & !ex_frame) as isize);
        let _ = SetParent(hwnd, Some(parent));
        let _ = SetWindowPos(hwnd, None, 0, 0, 0, 0,
            SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_ASYNCWINDOWPOS);
    }
}

fn place(hwnd: HWND, r: RECT) {
    let (w, h) = ((r.right - r.left).max(1), (r.bottom - r.top).max(1));
    unsafe {
        let _ = SetWindowPos(hwnd, Some(HWND_TOP), r.left, r.top, w, h, SWP_NOACTIVATE | SWP_ASYNCWINDOWPOS);
    }
}

fn show(hwnd: HWND, visible: bool) {
    unsafe {
        let _ = ShowWindowAsync(hwnd, if visible { SW_SHOWNA } else { SW_HIDE });
    }
}

fn exit_code(process: HANDLE) -> u32 {
    let mut code = 0u32;
    unsafe {
        let _ = GetExitCodeProcess(process, &mut code);
    }
    code
}

fn run(
    exe: &str,
    args: &str,
    cwd: &str,
    name: &str,
    parent: isize,
    rx: mpsc::Receiver<Cmd>,
    shared: &Shared,
) -> Result<()> {
    let mut parent = HWND(parent as *mut _);
    // Hidden from the start: Win32Application::Run shows its window with the
    // nCmdShow this sets, so it never flashes up on the desktop.
    let startup = STARTUPINFOW {
        cb: size_of::<STARTUPINFOW>() as u32,
        dwFlags: STARTF_USESHOWWINDOW,
        wShowWindow: SW_HIDE.0 as u16,
        ..Default::default()
    };
    let mut info = PROCESS_INFORMATION::default();
    let mut command_line: Vec<u16> = format!("\"{exe}\" {args}").encode_utf16().chain([0]).collect();
    unsafe {
        CreateProcessW(
            &HSTRING::from(exe),
            Some(PWSTR(command_line.as_mut_ptr())),
            None,
            None,
            false,
            PROCESS_CREATION_FLAGS(0),
            None,
            &HSTRING::from(cwd),
            &startup,
            &mut info,
        )
        .map_err(|e| anyhow!("cannot start {exe}: {e}"))?;
        let _ = CloseHandle(info.hThread);
    }
    let process = info.hProcess;
    shared.pid.store(info.dwProcessId, Ordering::Relaxed);

    let mut window: Option<HWND> = None;
    let mut bounds: Option<RECT> = None;
    let mut visible = false;
    let started = Instant::now();
    let result = (|| -> Result<()> {
        loop {
            loop {
                match rx.try_recv() {
                    Ok(Cmd::Bounds(r)) => {
                        bounds = Some(r);
                        if let Some(w) = window {
                            place(w, r);
                        }
                    }
                    Ok(Cmd::Visible(v)) => {
                        visible = v;
                        if let Some(w) = window {
                            show(w, v);
                        }
                    }
                    Ok(Cmd::Parent(p, done)) => {
                        parent = HWND(p as *mut _);
                        if let Some(w) = window {
                            unsafe {
                                let _ = SetParent(w, Some(parent));
                            }
                        }
                        let _ = done.send(());
                    }
                    Ok(Cmd::Close) | Err(mpsc::TryRecvError::Disconnected) => return Ok(()),
                    Err(mpsc::TryRecvError::Empty) => break,
                }
            }
            if window.is_none() {
                if let Some(w) = find_main_window(info.dwProcessId) {
                    adopt(w, parent);
                    if let Some(r) = bounds {
                        place(w, r);
                    }
                    show(w, visible);
                    window = Some(w);
                    shared.set_status(format!("running {name} (pid {})", info.dwProcessId));
                } else if started.elapsed() > Duration::from_secs(60) {
                    return Err(anyhow!("{name} opened no window within 60 s"));
                }
            }
            // The sample ended by itself (closed, or failed to start).
            if unsafe { WaitForSingleObject(process, 30) } == WAIT_OBJECT_0 {
                let code = exit_code(process);
                shared.set_status(if window.is_some() {
                    format!("exited (code {code})")
                } else {
                    format!("error: {name} exited (code {code}) before opening a window")
                });
                return Ok(());
            }
        }
    })();

    // Close: ask the sample to quit, then make sure it does.
    unsafe {
        if WaitForSingleObject(process, 0) != WAIT_OBJECT_0 {
            if let Some(w) = window {
                let _ = PostMessageW(Some(w), WM_CLOSE, WPARAM(0), LPARAM(0));
            }
            if WaitForSingleObject(process, 3000) != WAIT_OBJECT_0 {
                let _ = TerminateProcess(process, 1);
                WaitForSingleObject(process, 2000);
            }
            if shared.status.lock().unwrap().starts_with("running") || shared.status.lock().unwrap().starts_with("starting") {
                shared.set_status("closed");
            }
        }
        let _ = CloseHandle(process);
    }
    result
}
