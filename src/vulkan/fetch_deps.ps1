# Download what Vulkan-Samples needs but ewv does not carry: its third-party
# libraries (about 525 MB) and its assets (about 1 GB). They go into the
# git-ignored folders Vulkan-Samples\third_party\<name> and Vulkan-Samples\assets,
# each at the exact commit upstream pins (deps.tsv). Safe to re-run: a folder
# already at its pinned commit is skipped.
#
# The Windows counterpart of appine's src/backends/vulkan/fetch_deps.sh, and
# the same deps.tsv.
#
# Usage: .\fetch_deps.ps1              everything
#        .\fetch_deps.ps1 -NoAssets    libraries only (samples that load scenes
#                                      or textures will then fail to start)
param([switch]$NoAssets)
$ErrorActionPreference = 'Stop'

$root = Join-Path $PSScriptRoot 'Vulkan-Samples'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git not found.' }

function Invoke-Git {
    git @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed with exit code $LASTEXITCODE" }
}

foreach ($line in Get-Content (Join-Path $PSScriptRoot 'deps.tsv')) {
    if (-not $line -or $line.StartsWith('#')) { continue }
    $dep, $url, $commit = $line -split "`t"
    if ($dep -eq 'assets' -and $NoAssets) { continue }
    $dir = Join-Path $root $dep
    if ((Test-Path (Join-Path $dir '.git')) -and ((git -C $dir rev-parse HEAD 2>$null) -eq $commit)) {
        Write-Host "ok       $dep"
        continue
    }
    Write-Host "fetching $dep ($url @ $($commit.Substring(0, 10)))"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Invoke-Git -C $dir init -q
    # Some deps (KTX, tinygltf tests) have paths longer than MAX_PATH.
    Invoke-Git -C $dir config core.longpaths true
    Invoke-Git -C $dir fetch -q --depth 1 $url $commit
    Invoke-Git -C $dir -c advice.detachedHead=false checkout -q FETCH_HEAD
}

Write-Host ''
Write-Host "Dependencies ready under $root"
Write-Host 'Next: .\build.ps1   (in this folder)'
