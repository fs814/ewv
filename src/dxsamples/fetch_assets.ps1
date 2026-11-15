# Download the files of DirectX-Graphics-Samples that ewv does not carry:
# the ones over 1 MB (scenes, textures, models: 399 files, about 2.1 GB),
# listed with their git blob SHA-1 in large_files.tsv. Each comes from the
# upstream commit in UPSTREAM_COMMIT and is checked against that SHA-1; a file
# already present with the right content is skipped, so this is safe to re-run.
#
# Usage: .\fetch_assets.ps1                     everything
#        .\fetch_assets.ps1 -Match D3D12Multithreading   only paths containing it
param(
    [string]$Match = '',
    [int]$Parallel = 8
)
$ErrorActionPreference = 'Stop'

$root = Join-Path $PSScriptRoot 'DirectX-Graphics-Samples'
$commit = (Get-Content (Join-Path $PSScriptRoot 'UPSTREAM_COMMIT') -Raw).Trim()
$files = Get-Content (Join-Path $PSScriptRoot 'large_files.tsv') |
    Where-Object { $_ -and -not $_.StartsWith('#') } |
    ForEach-Object { $p, $s, $h = $_ -split "`t"; [pscustomobject]@{ Path = $p; Size = [long]$s; Sha = $h } } |
    Where-Object { -not $Match -or $_.Path -like "*$Match*" }

$results = $files | ForEach-Object -ThrottleLimit $Parallel -Parallel {
    $file = $_
    # git's blob id: SHA-1 of "blob <size>\0" followed by the content.
    function Get-BlobSha([string]$path) {
        $bytes = [IO.File]::ReadAllBytes($path)
        $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
        $sha = [Security.Cryptography.SHA1]::Create()
        $sha.TransformBlock($header, 0, $header.Length, $null, 0) | Out-Null
        $sha.TransformFinalBlock($bytes, 0, $bytes.Length) | Out-Null
        ($sha.Hash | ForEach-Object { $_.ToString('x2') }) -join ''
    }
    $target = Join-Path $using:root ($file.Path -replace '/', '\')
    if ((Test-Path -LiteralPath $target) -and (Get-Item -LiteralPath $target).Length -eq $file.Size -and
        (Get-BlobSha $target) -eq $file.Sha) {
        return "ok       $($file.Path)"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
    $escaped = (($file.Path -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    $url = "https://raw.githubusercontent.com/microsoft/DirectX-Graphics-Samples/$using:commit/$escaped"
    $part = "$target.part"
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $part
            if ((Get-BlobSha $part) -ne $file.Sha) { throw "SHA-1 mismatch" }
            Move-Item -LiteralPath $part -Destination $target -Force
            return "fetched  $($file.Path)"
        } catch {
            Remove-Item -LiteralPath $part -ErrorAction SilentlyContinue
            if ($attempt -eq 3) { return "FAILED   $($file.Path): $($_.Exception.Message)" }
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}
$results | Sort-Object | ForEach-Object { Write-Host $_ }
$failed = @($results | Where-Object { $_ -like 'FAILED*' })
Write-Host ''
Write-Host ("{0} files: {1} fetched, {2} already present, {3} failed" -f $files.Count,
    @($results | Where-Object { $_ -like 'fetched*' }).Count, @($results | Where-Object { $_ -like 'ok*' }).Count, $failed.Count)
if ($failed.Count) { exit 1 }
