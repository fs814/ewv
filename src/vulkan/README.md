# Khronos Vulkan-Samples

`M-x ewv-vulkan-sample` runs a sample from
[KhronosGroup/Vulkan-Samples](https://github.com/KhronosGroup/Vulkan-Samples)
in an Emacs buffer, through the GPU's own Vulkan driver. The Windows
counterpart of appine's `appine-vulkan-sample` (fs814/appine,
`src/backends/vulkan`), at the same upstream commit.

## Layout

| Path | What |
|---|---|
| `Vulkan-Samples/` | Upstream's code, copied unmodified at the commit in `UPSTREAM_COMMIT`: framework, all samples, shaders, CMake build. Apache-2.0 (`Vulkan-Samples/LICENSE`). |
| `Vulkan-Samples/third_party/*/`, `Vulkan-Samples/assets/` | Not in git. About 525 MB of libraries and 1 GB of scenes and textures, downloaded by `fetch_deps.ps1` at the commits upstream pins (`deps.tsv`, shared with appine). |
| `ewv/` | The ewv side: a platform for the samples' framework (`ewv_vulkan_samples.cpp`, ported from appine's, a Win32 child window instead of a `CAMetalLayer`), its C interface, and `ewv.cmake`, which adds the library to upstream's build without editing it. |
| `../vks.rs`, `../vks_lisp.rs` | The view: a child window of the Emacs frame with its own render thread, which loads the library, starts the sample and draws one frame at a time; and its `ewv-native-vks-*` functions. |
| `../../ewv-vulkan.el` | The command and the buffer that the view follows. |

## Building

The samples are a separate library, `ewv-vulkan-samples.dll` in the ewv root,
because the project is large (about 1300 build steps). `ewv_native.dll`
builds and runs without it, and loads it on first use.

```powershell
Settings\binwin\init\vulkan-init.ps1   # Vulkan SDK, once (D:\VulkanSDK\current)
src\vulkan\fetch_deps.ps1              # libraries and assets, once
src\vulkan\build.ps1                   # needs VS 2022 C++, CMake (and Ninja if present)
```

`cargo build` (or Settings' `build_ewv.ps1`) builds `ewv_native.dll` as
before; nothing in it depends on the samples library.

## Limits

- One sample at a time: the framework keeps global state. Starting another
  offers to stop the running one.
- A sample that needs something the GPU or driver lacks (ray tracing, some
  extensions, OpenGL or OpenCL interop) fails to start, and the buffer shows
  the framework's error.
- Left mouse button and drag are forwarded; keyboard is not. Clicking the
  view does not select its Emacs window.
- The library is loaded once per Emacs session (it cannot be unloaded), so a
  rebuilt one takes effect after restarting Emacs. To rebuild while Emacs has
  it loaded, rename `ewv-vulkan-samples.dll` first (Windows allows renaming a
  loaded DLL), like `ewv_native.dll`.

## Updating to a newer upstream

Copy upstream's tree over `Vulkan-Samples/` (without `.git`, the third-party
folders' contents and `assets/`), update `UPSTREAM_COMMIT` and `deps.tsv` from
its `.gitmodules` and `git submodule status`, then re-run `fetch_deps.ps1`.
Keep `deps.tsv` in step with appine's.
