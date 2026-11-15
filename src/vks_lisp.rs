// Lisp bindings for the Vulkan-Samples views (src/vks.rs). Included at the
// crate root, like dx12_lisp.rs, so the functions are named ewv-native-vks-*.

fn with_vks_view<F, T>(view_id: i64, f: F) -> LispResult<T>
where
    F: FnOnce(&vks::VkView) -> T,
{
    VKS_VIEWS.with(|views| {
        let views = views.borrow();
        let view = views
            .iter()
            .find(|v| v.id == view_id)
            .ok_or(anyhow!("no vulkan view with id({view_id}) found"))?;
        Ok(f(view))
    })
}

/// Open the Khronos Vulkan sample SAMPLE (an id such as "hello_triangle") as a
/// hidden child window of FRAME and return its id. LIBRARY is the path of
/// ewv-vulkan-samples.dll and ROOT the Vulkan-Samples folder (assets\ and
/// shaders\). The sample starts when the view is first shown: place it with
/// `ewv-native-vks-resize' and show it with `ewv-native-vks-set-visible'.
#[defun]
fn native_vks_open(
    sample: String,
    frame: emacs::Value,
    library: String,
    root: String,
) -> LispResult<i64> {
    let hwnd = get_frame_hwnd(frame)?;
    let view = vks::VkView::open(&sample, hwnd, &library, &root)?;
    let id = view.id;
    VKS_VIEWS.with(|views| views.borrow_mut().push(view));
    Ok(id)
}

/// Move the view to BOUNDS, a list (LEFT TOP RIGHT BOTTOM) in pixels relative
/// to its frame, as `window-body-pixel-edges' returns.
#[defun]
fn native_vks_resize(view_id: i64, bounds: Value) -> LispResult<()> {
    let bounds = rect_from_lisp(bounds)?;
    with_vks_view(view_id, |view| view.resize(bounds))
}

#[defun]
fn native_vks_set_visible(view_id: i64, visible: Value) -> LispResult<()> {
    let visible = visible.is_not_nil();
    with_vks_view(view_id, |view| view.set_visible(visible))
}

#[defun]
fn native_vks_reparent(view_id: i64, frame: emacs::Value) -> LispResult<()> {
    let hwnd = get_frame_hwnd(frame)?;
    with_vks_view(view_id, |view| view.reparent(hwnd))
}

/// What the sample is doing: "starting", "running <sample>", "error: ..."
/// when it could not start or stopped, or "closed".
#[defun]
fn native_vks_status(view_id: i64) -> LispResult<String> {
    with_vks_view(view_id, |view| view.status())
}

/// Number of frames the sample has drawn so far.
#[defun]
fn native_vks_frame_count(view_id: i64) -> LispResult<i64> {
    with_vks_view(view_id, |view| view.frames() as i64)
}

/// Stop the sample, its render thread and its window.
#[defun]
fn native_vks_close(view_id: i64) -> LispResult<()> {
    VKS_VIEWS.with(|views| {
        let mut views = views.borrow_mut();
        if let Some(view) = views.iter().find(|v| v.id == view_id) {
            view.close();
        }
        views.retain(|v| v.id != view_id);
    });
    Ok(())
}
