# Microsoft DirectX-Graphics-Samples

`M-x ewv-dxsample` (and `M-x winine-dxsample`) runs one of
[microsoft/DirectX-Graphics-Samples](https://github.com/microsoft/DirectX-Graphics-Samples)
in an Emacs buffer: the D3D12 samples (`Samples/Desktop`), MiniEngine's
ModelViewer and the technique demos, 61 programs in all (`projects.tsv`).

## How it works

Every sample stays the Win32 program upstream wrote, built unchanged by
MSBuild. A view (ewv: `../dxs.rs`, winine: `../../winine/src/dxs.cpp`) starts
the program hidden, waits for its main window, removes its caption and border,
makes it a child window of the Emacs frame, and from then on keeps it over the
buffer's window: placed, shown and hidden as the buffer is displayed, moved
with it to another frame. So:

- a sample keeps its own process, message loop and keyboard input: click the
  view to type to it, click an Emacs window to type to Emacs;
- a sample that crashes ends only its buffer's view, and several samples run
  at once;
- killing the buffer closes the program (`WM_CLOSE`, then terminated after
  3 s), and so does quitting Emacs.

## Layout

| Path | What |
|---|---|
| `DirectX-Graphics-Samples/` | Upstream's tree, copied unmodified at the commit in `UPSTREAM_COMMIT`, minus its files over 1 MB. MIT (`DirectX-Graphics-Samples/LICENSE`). |
| `large_files.tsv` | Those files (399, about 2.1 GB of scenes, textures and models): path, size, git blob SHA-1. Not in git (`.gitignore`). |
| `fetch_assets.ps1` | Downloads them from the upstream commit and checks each SHA-1. |
| `build.ps1` | Builds samples with MSBuild (restoring their NuGet packages first) and writes `projects.tsv`. |
| `projects.tsv` | Every runnable sample: name, category, project, exe. What the Emacs side lists. |

## Use

```powershell
src\dxsamples\fetch_assets.ps1                    # scenes and textures, once (-Match D3D12Multithreading: just one sample's)
src\dxsamples\build.ps1 D3D12HelloTriangle        # one or more samples by name; -All for every one
```

`M-x ewv-dxsample` offers to build a sample that is not built yet, in a
compilation buffer, and starts it when the build succeeds. In its buffer:
`r` restarts it, `s` shows its status, `g` re-syncs the view, `k` kills it.

Needs Visual Studio 2022 with the C++ workload and the Windows SDK; MSBuild
restores each sample's packages (the D3D12 Agility SDK, DXC, ...) into its
solution's `packages` folder. Some samples need hardware features (ray
tracing, mesh shaders, variable rate shading, several GPUs) or extra SDKs and
say so when they start or fail to build.

## Build status

On the machine this was set up on (Visual Studio 2022 17.14), 58 of the 61
samples build. The other three are tools, not visual samples, and need what
upstream assumes is installed:

- `D3D12WavefrontConverter`, `D3D12OMMOfflineBaker`: packages from upstream's
  `vcpkg.json` (OMM SDK, ...) in vcpkg manifest mode; a machine-wide
  `vcpkg integrate install` gets in the way of upstream's own vcpkg import.
- `DXGIAdapterRemovalSupportTest`: `nt.h`, from the Windows Driver Kit.

`build.ps1 -All` builds the samples in `projects.tsv` and skips these three
(`$NotBuildable`); name one to try it anyway. The tree's other `.vcxproj`
files (MiniEngine's `AppTemplate` project template, `SDFFontCreator_VS15`)
are not samples and are never built.

`D3D12Residency` includes `Libraries/D3DX12Residency/d3dx12Residency.h`
without having that folder on its include path; `build.ps1` adds it
(`$ExtraIncludes`) so the vendored project stays unmodified.

## Notes

- Upstream force-added five files that its own `.gitignore` ignores (two
  `.vcxproj.user` files and the three `D3D12Raytracing/tools/x64` scripts);
  `git add -f` them when committing this folder.
- Samples are not DPI-aware: on a scaled display Windows stretches their
  output to the window.
- Built output (`bin/`, `obj/`, `packages/`, MiniEngine's `Build/`) is ignored
  by upstream's `.gitignore`.

## Updating to a newer upstream

Replace `DirectX-Graphics-Samples/` with the new commit's files of 1 MB or
less, regenerate `large_files.tsv` and `.gitignore` from `git ls-tree -r -l`
(the files over 1 MB), update `UPSTREAM_COMMIT`, then run `build.ps1 -Index`
and `fetch_assets.ps1`.
