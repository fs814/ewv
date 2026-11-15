# Build ewv-vulkan-samples.dll: Khronos Vulkan-Samples plus ewv's platform
# (ewv\ewv_vulkan_samples.cpp), into the ewv root next to ewv_native.dll.
#
# The Windows counterpart of appine's `make vulkan-samples`. A separate library
# because the project is large (about 1300 build steps); ewv_native.dll builds
# and runs without it and loads it on first use (M-x ewv-vulkan-sample).
#
# Needs: the Vulkan SDK (Settings\binwin\init\vulkan-init.ps1, which keeps
# D:\VulkanSDK\current), fetch_deps.ps1 run once, Visual Studio 2022 with the
# C++ workload, CMake and Ninja (falls back to the VS generator without Ninja).
#
# Shaders are not recompiled (VKB_BUILD_SHADERS=OFF): upstream commits the
# compiled .spv files the samples load, and its shader step writes its output
# back into Vulkan-Samples\shaders - which would change the vendored copy, and
# with Ninja's parallel jobs, samples sharing one shader collide on that copy.
#
# Usage: .\build.ps1 [-Config Release|Debug] [-Clean]
param(
    [ValidateSet('Release', 'Debug', 'RelWithDebInfo')][string]$Config = 'Release',
    [switch]$Clean
)
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$src = Join-Path $here 'Vulkan-Samples'
$ewvRoot = (Resolve-Path (Join-Path $here '..\..')).Path
$buildDir = Join-Path $ewvRoot 'build\vulkan-samples'

if (-not (Test-Path (Join-Path $src 'third_party\volk\volk.h'))) {
    throw "Dependencies missing: run $here\fetch_deps.ps1 first."
}

# The Vulkan SDK: the session's, else the Machine one, else the junction.
$sdk = @($env:VULKAN_SDK, [Environment]::GetEnvironmentVariable('VULKAN_SDK', 'Machine'), 'D:\VulkanSDK\current') |
    Where-Object { $_ -and (Test-Path (Join-Path $_ 'Include\vulkan\vulkan.h')) } | Select-Object -First 1
if (-not $sdk) { throw 'Vulkan SDK not found: run Settings\binwin\init\vulkan-init.ps1.' }
$env:VULKAN_SDK = $sdk
$env:PATH = "$sdk\Bin;$env:PATH"   # glslc / slangc for the samples' shaders

# MSVC: import vcvars64 into this session unless cl.exe is already set up.
# vcvars runs under a short PATH: cmd.exe rejects a very long one ("The input
# line is too long") and vcvars itself needs vswhere.exe on PATH. The session's
# own PATH goes back after the MSVC folders, so cl.exe wins over any MinGW cc.
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    $installer = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer"
    $vs = & "$installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { throw 'Visual Studio with the C++ workload not found.' }
    $vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
    $sessionPath = $env:PATH
    $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\WindowsPowerShell\v1.0;$installer"
    try {
        $vars = cmd.exe /c "`"$vcvars`" >nul && set"
    } finally {
        $env:PATH = $sessionPath
    }
    foreach ($line in $vars) {
        if ($line -match '^([^=]+)=(.*)$') {
            $value = if ($Matches[1] -eq 'Path') { "$($Matches[2]);$sessionPath" } else { $Matches[2] }
            Set-Item -Path "env:$($Matches[1])" -Value $value
        }
    }
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) { throw "vcvars64 did not set up cl.exe ($vcvars)." }
}

if ($Clean -and (Test-Path $buildDir)) { Remove-Item -Recurse -Force $buildDir }

$generator = if (Get-Command ninja -ErrorAction SilentlyContinue) { @('-G', 'Ninja') } else { @() }
$hook = (Join-Path $here 'ewv\ewv.cmake') -replace '\\', '/'
$out = $ewvRoot -replace '\\', '/'

cmake @generator -S $src -B $buildDir `
    "-DCMAKE_BUILD_TYPE=$Config" `
    '-DCMAKE_C_COMPILER=cl.exe' '-DCMAKE_CXX_COMPILER=cl.exe' `
    -DVKB_BUILD_TESTS=OFF `
    -DVKB_BUILD_SHADERS=OFF `
    -DVKB_WARNINGS_AS_ERRORS=OFF `
    "-DCMAKE_PROJECT_INCLUDE=$hook" `
    "-DEWV_VKS_OUTPUT_DIR=$out"
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed with exit code $LASTEXITCODE" }

cmake --build $buildDir --config $Config --target ewv_vulkan_samples
if ($LASTEXITCODE -ne 0) { throw "cmake build failed with exit code $LASTEXITCODE" }

$dll = Join-Path $ewvRoot 'ewv-vulkan-samples.dll'
if (-not (Test-Path $dll)) { throw "Build did not produce $dll" }
Write-Host ''
Write-Host "Built $dll"
Write-Host 'In Emacs: M-x ewv-vulkan-sample'
