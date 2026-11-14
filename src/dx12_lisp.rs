// Lisp bindings for the Direct3D 12 demo views (src/dx12/). Included at the
// crate root, like lisp.rs, so the functions are named ewv-native-dx12-*.

fn with_dx12_view<F, T>(view_id: i64, f: F) -> LispResult<T>
where
    F: FnOnce(&dx12::DxView) -> T,
{
    DX12_VIEWS.with(|views| {
        let views = views.borrow();
        let view = views
            .iter()
            .find(|v| v.id == view_id)
            .ok_or(anyhow!("no dx12 view with id({view_id}) found"))?;
        Ok(f(view))
    })
}

/// Open the Direct3D 12 demo DEMO ("triangle" or "raytracing") as a hidden
/// child window of FRAME and return its id. Place it with
/// `ewv-native-dx12-resize' and show it with `ewv-native-dx12-set-visible'.
#[defun]
fn native_dx12_open(demo: String, frame: emacs::Value) -> LispResult<i64> {
    let hwnd = get_frame_hwnd(frame)?;
    let view = dx12::DxView::open(&demo, hwnd)?;
    let id = view.id;
    DX12_VIEWS.with(|views| views.borrow_mut().push(view));
    Ok(id)
}

/// Move the demo view to BOUNDS, a list (LEFT TOP RIGHT BOTTOM) in pixels
/// relative to its frame, as `window-body-pixel-edges' returns.
#[defun]
fn native_dx12_resize(view_id: i64, bounds: Value) -> LispResult<()> {
    let bounds = rect_from_lisp(bounds)?;
    with_dx12_view(view_id, |view| view.resize(bounds))
}

#[defun]
fn native_dx12_set_visible(view_id: i64, visible: Value) -> LispResult<()> {
    let visible = visible.is_not_nil();
    with_dx12_view(view_id, |view| view.set_visible(visible))
}

#[defun]
fn native_dx12_reparent(view_id: i64, frame: emacs::Value) -> LispResult<()> {
    let hwnd = get_frame_hwnd(frame)?;
    with_dx12_view(view_id, |view| view.reparent(hwnd))
}

/// What the demo is doing: "starting", "running on <GPU>", "error: ..." when
/// it could not start or stopped (for example no GPU with ray tracing), or
/// "closed".
#[defun]
fn native_dx12_status(view_id: i64) -> LispResult<String> {
    with_dx12_view(view_id, |view| view.status())
}

/// Number of frames the demo has presented so far.
#[defun]
fn native_dx12_frame_count(view_id: i64) -> LispResult<i64> {
    with_dx12_view(view_id, |view| view.frames() as i64)
}

/// Stop the demo's render thread and destroy its window.
#[defun]
fn native_dx12_close(view_id: i64) -> LispResult<()> {
    DX12_VIEWS.with(|views| {
        let mut views = views.borrow_mut();
        if let Some(view) = views.iter().find(|v| v.id == view_id) {
            view.close();
        }
        views.retain(|v| v.id != view_id);
    });
    Ok(())
}
