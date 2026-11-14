use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=Cargo.toml");
    patch_crate::run().expect("Failed while patching");

    compile_raytracing_shaders();
}

/// The DXR shader library (src/dx12/raytracing/shaders.hlsl) is a `lib_6_3`
/// target, which only dxc can build (D3DCompile stops at shader model 5), and
/// Windows ships no dxcompiler.dll to do it at run time. So it is compiled here
/// and embedded in the DLL with `include_bytes!`. dxc.exe comes with the
/// Windows SDK; sitting next to dxil.dll there, it also signs the output, which
/// D3D12 requires.
fn compile_raytracing_shaders() {
    let source = Path::new("src/dx12/raytracing/shaders.hlsl");
    println!("cargo:rerun-if-changed={}", source.display());
    println!("cargo:rerun-if-env-changed=DXC");

    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("raytracing_shaders.dxil");
    let dxc = find_dxc().expect(
        "dxc.exe not found: install the Windows SDK, or set DXC to the path of dxc.exe",
    );
    let status = Command::new(&dxc)
        .args(["-nologo", "-T", "lib_6_3", "-Fo"])
        .arg(&out)
        .arg(source)
        .status()
        .unwrap_or_else(|e| panic!("failed to run {}: {e}", dxc.display()));
    assert!(status.success(), "dxc failed to compile {}", source.display());
}

fn find_dxc() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("DXC") {
        return Some(PathBuf::from(path));
    }
    // Newest installed SDK version.
    let mut candidates: Vec<PathBuf> = Vec::new();
    for root in ["ProgramFiles(x86)", "ProgramFiles"] {
        let Some(root) = std::env::var_os(root) else { continue };
        let bin = PathBuf::from(root).join("Windows Kits").join("10").join("bin");
        let Ok(entries) = std::fs::read_dir(&bin) else { continue };
        for entry in entries.flatten() {
            let exe = entry.path().join("x64").join("dxc.exe");
            if exe.is_file() {
                candidates.push(exe);
            }
        }
    }
    candidates.sort();
    if let Some(newest) = candidates.pop() {
        return Some(newest);
    }
    // Otherwise whatever is on PATH.
    Command::new("dxc")
        .arg("--version")
        .output()
        .ok()
        .map(|_| PathBuf::from("dxc"))
}
