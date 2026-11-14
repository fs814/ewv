# Direct3D 12 sample demos

Two Direct3D 12 demos running in Emacs buffers. They are the Windows
counterpart of [appine](https://github.com/fs814/appine)'s Metal demos
(`src/backends/metal/` there), which run two of Apple's Metal samples in appine
tabs on macOS:

| Command | Directory | What it draws | appine / Metal counterpart |
|---|---|---|---|
| `M-x ewv-dx12-triangle` | `triangle/` | A colorful, rotating triangle | `appine-metal-triangle` (Drawing a triangle with Metal 4) |
| `M-x ewv-dx12-raytracing` | `raytracing/` | A path-traced grid of Cornell boxes (DirectX Raytracing) | `appine-metal-raytracing` (Accelerating ray tracing using Metal) |

The demos are written for this module, not ported file by file: Apple's
samples are Objective-C against Metal, and nothing of them carries over to
Rust and Direct3D 12. What carries over is what each one shows, listed in the
READMEs of the two directories.

## How a demo sits in Emacs

`../../ewv-dx12.el` gives each demo a buffer (`*ewv-dx12-triangle*`,
`*ewv-dx12-raytracing*`). The buffer owns a native view and keeps it over
whichever window shows the buffer, the way `ewv-browser` does for a webview:
split, resize, switch away and back, or show it in another frame. Killing the
buffer closes the view. In the buffer, `q` buries it, `k` kills it, `s` shows
the status and frame count, `g` re-syncs the view with its window.

A view is a child window of the Emacs frame (`mod.rs`):

- **Its own thread.** The thread creates the window, owns every Direct3D
  object, pumps the window's messages and renders with vsync. Nothing is drawn
  on the Lisp thread or the frame's input thread, so a slow frame cannot stall
  Emacs. Lisp only sends the thread commands: place, show or hide, move to
  another frame, close.
- **No input.** The window is disabled, so the mouse falls through to Emacs:
  clicking a demo selects its Emacs window, and every key stays with Emacs.
  (appine needs an active and an inactive state for its tabs because they take
  input; these views never do.)
- **Hidden means stopped.** A view whose buffer is not displayed is hidden and
  does not render; the ray tracer keeps its accumulated image and continues
  when shown again.
- **Frames can go.** Windows destroys a frame's child windows with it, so
  before a frame is deleted its views are moved to another frame
  (`ewv-dx12--delete-frame`). That move waits for the render thread; the other
  commands do not.

The Lisp bindings (`ewv-native-dx12-*`) are in `../dx12_lisp.rs`.

## When a demo cannot run

Like appine's tabs, which show a message when a Mac cannot run a demo: if no
Direct3D 12 GPU is found, or no GPU supports DirectX Raytracing for the ray
tracer, or a shader or pipeline fails to build, no view appears and the
buffer's text says why (`ewv-native-dx12-status`). On a machine with several
GPUs both demos pick the fastest one; the ray tracer picks the fastest one
that supports ray tracing.

## Shaders

- `triangle/shaders.hlsl` is compiled when the demo first starts, with
  `D3DCompile` from the `d3dcompiler_47.dll` that ships with Windows.
- `raytracing/shaders.hlsl` is a DXR shader library (`lib_6_3`), which only
  the newer `dxc` compiler can build, and Windows ships no `dxcompiler.dll` to
  do that at run time. `../../build.rs` compiles it with `dxc.exe` from the
  Windows SDK and the DLL embeds the result. So **building** the module needs
  the Windows SDK (or `DXC` set to a `dxc.exe`); **running** it needs nothing
  extra.

appine has the same split for a different reason: its Makefile embeds the
Metal shader sources and compiles them at first use, because Emacs has no app
bundle to hold a `default.metallib`.
