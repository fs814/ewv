# winine

ewv with its native module written in C++. Everything ewv does, under the
`winine-` prefix, and loadable next to ewv in the same Emacs:

| Command | What |
|---|---|
| `M-x winine-browser-open-url`, `-open-file`, `-open-history`, `-reopen-all-pinned-tabs` | Edge WebView2 browser in Emacs windows |
| `M-x winine-dx12-triangle`, `winine-dx12-raytracing` | the Direct3D 12 demos |
| `M-x winine-vulkan-sample` | Khronos Vulkan-Samples |
| `M-x winine-dxsample` | Microsoft DirectX-Graphics-Samples (ewv's `../src/dxsamples`) |
| `M-x winine-rss` | the RSS reader |
| (in every browser tab) | link hints and the selection assistant |

## Layout

| Path | What |
|---|---|
| `src/` | `winine_native.dll`: the C++ module. Same functions and arguments as ewv's Rust module, as `winine-native-*` (49 of them). |
| `src/lisp.*` | The Emacs side: `emacs_env` wrapper, function registration, the event queues that carry WebView2 callbacks to Lisp. |
| `src/webview.*` | WebView2 (ewv's `src/webview.rs`): environment, views, events, scripts, web messages, the `bridge` host object, the frame-thread focus hook. |
| `src/view.*` | What the DX12 and Vulkan views share: a render thread owning a child window of the frame, driven by commands from Lisp. |
| `src/dx12/` | The Direct3D 12 demos (ewv's `src/dx12`). `triangle.hlsl` (fxc) and `raytracing.hlsl` (dxc, DXR `lib_6_3`) are compiled at build time and embedded. |
| `src/vks.*` | The Vulkan-Samples view (ewv's `src/vks.rs`). |
| `src/dxs.*` | The DirectX-Graphics-Samples view (ewv's `src/dxs.rs`): starts a sample's program and adopts its window into the frame. |
| `*.el`, `*.html`, `*.svg`, `plugins/` | ewv's Lisp and web assets, with every `ewv` name changed to `winine`. |

Shared with ewv: the Vulkan samples library `../ewv-vulkan-samples.dll` and
its `../src/vulkan/Vulkan-Samples` tree (`winine-vulkan-library`,
`winine-vulkan-samples-root`), and the DirectX-Graphics-Samples in
`../src/dxsamples` (`winine-dxsamples-dir`). Nothing else.

## Building

`Settings\winbuild\editor\emacsplugin\ewv\build_ewv.ps1` builds ewv (cargo)
and then winine (CMake, MSVC, Ninja when present) into
`winine\winine_native.dll`, which `winine-core.el` loads. `-SkipEwv` builds
only winine; `-Vulkan`, `-DxSamples` (or `-All`) also build the Vulkan-Samples
library and the DirectX-Graphics-Samples. It needs:

- Visual Studio 2022 with C++ and the Windows SDK (fxc, dxc).
- The Microsoft.Web.WebView2 NuGet package, version pinned in the script: from
  the NuGet cache, else downloaded into `build\packages`.
- `emacs-module.h` (`$env:EMACS_INCLUDE_DIR`, default `C:\emacsrelease\include`).
- For the Vulkan samples only: ewv's `ewv-vulkan-samples.dll`
  (`build_ewv.ps1 -Vulkan`).

A running Emacs keeps the DLL open; the script renames it out of the way first
(`winine_native.dll.old<time>`), so a rebuild takes effect in a new Emacs.

## Trying it

```powershell
emacs --debug-init -Q -L D:\sourcenew\editor\emacsplugin\ewv\winine -l winine.el
```

then `M-x winine-browser-open-url`. Set `winine-browser-user-data-folder`
first to keep its profile away from ewv's.

## Differences from ewv

- The module provides the feature `winine-native`; `winine.el` provides `winine`.
- The `bridge` host object (modeline.html) calls `winine-core--eval-string`;
  ewv's calls `ewv--eval-string`, which does not exist.
- Closing a DX12 view waits for its render thread, as Vulkan views do in both.
