# Build samples of Microsoft's DirectX-Graphics-Samples (the vendored copy in
# DirectX-Graphics-Samples\) with MSBuild, unchanged: each is its own Win32
# program, which ewv / winine run and embed in an Emacs buffer
# (M-x ewv-dxsample, M-x winine-dxsample; README.md here).
#
# Usage:
#   .\build.ps1 D3D12HelloTriangle [D3D12nBodyGravity ...]   build these (project names)
#   .\build.ps1 -All                build every sample in projects.tsv (continues past
#                                   failures; skips the tools in $NotBuildable)
#   .\build.ps1 -Index              (re)write projects.tsv only
#   options: -Config Release|Debug
#
# projects.tsv lists every runnable sample (name, category, project, exe) and
# is what the Emacs side reads. Each build first restores the project's NuGet
# packages (packages.config: the D3D12 Agility SDK, DXC, ...) into its
# solution's packages folder, as Visual Studio would. Needs Visual Studio 2022
# with the C++ workload (and the Windows SDK); fetch_assets.ps1 first for
# samples that load scenes or textures.
param(
    [Parameter(Position = 0, ValueFromRemainingArguments)][string[]]$Project,
    [switch]$All,
    [switch]$Index,
    [ValidateSet('Release', 'Debug')][string]$Config = 'Release'
)
$ErrorActionPreference = 'Stop'

$root = Join-Path $PSScriptRoot 'DirectX-Graphics-Samples'
$indexFile = Join-Path $PSScriptRoot 'projects.tsv'

$msbuild = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * `
    -requires Microsoft.Component.MSBuild Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find 'MSBuild\**\Bin\MSBuild.exe' |
    Select-Object -First 1
if (-not $msbuild) { throw 'MSBuild with the C++ workload not found (Visual Studio 2022).' }

# The folder Visual Studio would restore packages for: the nearest one up
# from the project that holds a solution (packages.config paths are relative
# to it, e.g. ..\packages).
function Get-SolutionDir([string]$project) {
    $dir = Split-Path $project
    while ($dir -and $dir.Length -ge $root.Length) {
        if (Get-ChildItem -LiteralPath $dir -File | Where-Object Extension -in '.sln', '.slnx') { return "$dir\" }
        $dir = Split-Path $dir
    }
    "$(Split-Path (Split-Path $project))\"
}

# Every x64 Application project in the tree.
function Get-SampleProjects {
    Get-ChildItem -LiteralPath $root -Recurse -Filter *.vcxproj | Where-Object {
        $text = Get-Content -LiteralPath $_.FullName -Raw
        $text -match '<ConfigurationType>Application</ConfigurationType>' -and $text -match "Include=`"$Config\|x64`""
    } | Sort-Object FullName
}

function Get-Category([string]$project) {
    $relative = $project.Substring($root.Length + 1) -split '\\'
    switch ($relative[0]) {
        'Samples' { if ($relative.Length -gt 2) { $relative[2] } else { 'Samples' } }
        default { $relative[0] }
    }
}

function Write-Index {
    $lines = @("# Runnable DirectX-Graphics-Samples (written by build.ps1 -Index): name<TAB>category<TAB>project<TAB>exe,",
               "# paths relative to DirectX-Graphics-Samples\. The exe exists once the sample is built.")
    foreach ($p in Get-SampleProjects) {
        $target = & $msbuild $p.FullName -nologo "-p:Configuration=$Config" -p:Platform=x64 `
                     "-p:SolutionDir=$(Get-SolutionDir $p.FullName)" -getProperty:TargetPath 2>$null |
                  Where-Object { $_ -match '\.exe\s*$' } | Select-Object -Last 1
        if (-not $target) { Write-Warning "no TargetPath for $($p.FullName.Substring($root.Length + 1))"; continue }
        $target = $target.Trim()
        $exe = [IO.Path]::GetFullPath($target)
        $relProject = $p.FullName.Substring($root.Length + 1)
        $relExe = if ($exe.StartsWith($root, 'OrdinalIgnoreCase')) { $exe.Substring($root.Length + 1) } else { $exe }
        $lines += "$($p.BaseName)`t$(Get-Category $p.FullName)`t$relProject`t$relExe"
    }
    [IO.File]::WriteAllLines($indexFile, $lines)
    Write-Host "Wrote $indexFile ($($lines.Count - 2) samples)"
}

# Headers some upstream projects use without putting them on their include
# path; added through cl.exe's CL variable, for that project's build only.
$ExtraIncludes = @{
    'D3D12Residency' = 'Libraries\D3DX12Residency'        # d3dx12Residency.h
}

function Build-Project([IO.FileInfo]$p) {
    $solution = Get-SolutionDir $p.FullName
    Write-Host "==> $($p.BaseName)"
    $savedCl = $env:CL
    if ($ExtraIncludes.ContainsKey($p.BaseName)) {
        $env:CL = "/I`"$(Join-Path $root $ExtraIncludes[$p.BaseName])`" $savedCl"
    }
    try {
        Invoke-ProjectBuild $p $solution
    } finally {
        $env:CL = $savedCl
    }
}

function Invoke-ProjectBuild([IO.FileInfo]$p, [string]$solution) {
    # Out-Host: MSBuild's lines go to the console, not into this function's
    # result (which must be just the success flag).
    if (Test-Path -LiteralPath (Join-Path $p.DirectoryName 'packages.config')) {
        & $msbuild $p.FullName -nologo -v:m -t:restore -p:RestorePackagesConfig=true "-p:SolutionDir=$solution" | Out-Host
        if ($LASTEXITCODE -ne 0) { return $false }
    }
    & $msbuild $p.FullName -nologo -v:m -m "-p:Configuration=$Config" -p:Platform=x64 "-p:SolutionDir=$solution" | Out-Host
    $LASTEXITCODE -eq 0
}

if ($Index -or -not (Test-Path -LiteralPath $indexFile)) { Write-Index }
if ($Index -and -not $All -and -not $Project) { exit 0 }

# Tools that need what this setup does not provide (README.md, Build status).
# -All skips them; naming one still tries it.
$NotBuildable = [ordered]@{
    'D3D12WavefrontConverter'       = 'vcpkg manifest packages'
    'D3D12OMMOfflineBaker'          = 'vcpkg manifest packages (OMM SDK)'
    'DXGIAdapterRemovalSupportTest' = 'nt.h from the Windows Driver Kit'
}

$projects = Get-SampleProjects
if ($All) {
    # The indexed samples only: other .vcxproj files are templates and old
    # tools (MiniEngine's AppTemplate, SDFFontCreator_VS15) with no target.
    $indexed = Get-Content -LiteralPath $indexFile | Where-Object { $_ -and -not $_.StartsWith('#') } |
        ForEach-Object { ($_ -split "`t")[0] }
    $projects = $projects | Where-Object { $_.BaseName -in $indexed }
    $skipped = $projects | Where-Object { $NotBuildable.Contains($_.BaseName) }
    foreach ($p in $skipped) { Write-Host "Skipping $($p.BaseName): needs $($NotBuildable[$p.BaseName])" }
    $projects = @($projects | Where-Object { -not $NotBuildable.Contains($_.BaseName) })
} else {
    if (-not $Project) { throw 'Name the samples to build (e.g. D3D12HelloTriangle), or pass -All.' }
    $projects = foreach ($name in $Project) {
        $match = $projects | Where-Object { $_.BaseName -eq $name -or $_.FullName -eq [IO.Path]::GetFullPath($name) }
        if (-not $match) { throw "No sample project named $name (see projects.tsv)." }
        $match
    }
}

$failed = @()
foreach ($p in $projects) {
    if (-not (Build-Project $p)) {
        $failed += $p.BaseName
        if (-not $All) { break }
    }
}
Write-Host ''
Write-Host ("Built {0} of {1} samples." -f ($projects.Count - $failed.Count), $projects.Count)
if ($All -and $skipped) { Write-Host "Skipped: $(@($skipped.BaseName) -join ', ')" }
if ($failed) {
    Write-Host "Failed: $($failed -join ', ')"
    exit 1
}
