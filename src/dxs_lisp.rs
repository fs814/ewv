// Lisp bindings for the DirectX-Graphics-Samples views (src/dxs.rs). Included
// at the crate root, like dx12_lisp.rs, so the functions are ewv-native-dxs-*.

fn with_dxs_view<F, T>(view_id: i64, f: F) -> LispResult<T>
where
    F: FnOnce(&dxs::DxsView) -> T,
{
    DXS_VIEWS.with(|views| {
        let views = views.borrow();
        let view = views
            .iter()
            .find(|v| v.id == view_id)
            .ok_or(anyhow!("no dxsample view with id({view_id}) found"))?;
        Ok(f(view))
    })
}

/// Start EXE (a built DirectX-Graphics-Samples program) with ARGS (a command
/// line tail, "" for none) in the folder CWD, and embed its window in FRAME
/// once it opens one. Return the view's id. Place it with
/// `ewv-native-dxs-resize' and show it with `ewv-native-dxs-set-visible'.
#[defun]
fn native_dxs_open(exe: String, args: String, cwd: String, frame: emacs::Value) -> LispResult<i64> {
    let hwnd = get_frame_hwnd(frame)?;
    let view = dxs::DxsView::open(&exe, &args, &cwd, hwnd)?;
    let id = view.id;
    DXS_VIEWS.with(|views| views.borrow_mut().push(view));
    Ok(id)
}

/// Move the view to BOUNDS, (LEFT TOP RIGHT BOTTOM) in frame pixels.
#[defun]
fn native_dxs_resize(view_id: i64, bounds: Value) -> LispResult<()> {
    let bounds = rect_from_lisp(bounds)?;
    with_dxs_view(view_id, |view| view.resize(bounds))
}

#[defun]
fn native_dxs_set_visible(view_id: i64, visible: Value) -> LispResult<()> {
    let visible = visible.is_not_nil();
    with_dxs_view(view_id, |view| view.set_visible(visible))
}

#[defun]
fn native_dxs_reparent(view_id: i64, frame: emacs::Value) -> LispResult<()> {
    let hwnd = get_frame_hwnd(frame)?;
    with_dxs_view(view_id, |view| view.reparent(hwnd))
}

/// "starting", "running <sample> (pid N)", "exited (code N)", "error: ..."
/// or "closed".
#[defun]
fn native_dxs_status(view_id: i64) -> LispResult<String> {
    with_dxs_view(view_id, |view| view.status())
}

/// The sample's process id (0 before it started).
#[defun]
fn native_dxs_pid(view_id: i64) -> LispResult<i64> {
    with_dxs_view(view_id, |view| view.pid() as i64)
}

/// Close the sample and wait for it to exit.
#[defun]
fn native_dxs_close(view_id: i64) -> LispResult<()> {
    DXS_VIEWS.with(|views| {
        let mut views = views.borrow_mut();
        if let Some(view) = views.iter().find(|v| v.id == view_id) {
            view.close();
        }
        views.retain(|v| v.id != view_id);
    });
    Ok(())
}
