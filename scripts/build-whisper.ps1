#requires -Version 7
# Build whisper.cpp for Windows (CUDA by default, CPU-only fallback).
# Outputs: bin\whisper-server.exe and bin\whisper-cli.exe
#   -Force      Rebuild even if both binaries already exist.
#   -CpuOnly    Skip CUDA, build CPU-only (faster; base.en is fast on CPU anyway).
param([switch]$Force, [switch]$CpuOnly)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$src  = Join-Path $repo "external\whisper.cpp"
$bin  = Join-Path $repo "bin"
. "$PSScriptRoot\_models.ps1"

$serverExe = Join-Path $bin "whisper-server.exe"
$cliExe    = Join-Path $bin "whisper-cli.exe"
if (-not $Force -and (Test-Path $serverExe) -and (Test-Path $cliExe)) {
    Write-Host "whisper-server.exe + whisper-cli.exe already built — skipping (use -Force to rebuild)." -ForegroundColor DarkGray
    return
}

if (-not (Test-Path (Join-Path $src "CMakeLists.txt"))) {
    throw "whisper.cpp submodule not found at $src. Run: git submodule update --init --recursive"
}

# --- resolve cmake (same logic as build-llama.ps1 to avoid cmake 4.x incompatibility) ---
$cmakeExe = $null
$pathCmake = Get-Command cmake -ErrorAction SilentlyContinue
if ($pathCmake) {
    $cmakeVer = (& cmake --version 2>&1 | Select-Object -First 1) -replace 'cmake version\s+', ''
    if ([version]$cmakeVer -lt [version]'4.0') {
        $cmakeExe = 'cmake'
    } else {
        Write-Warning "PATH cmake is $cmakeVer (4.x) — incompatible with whisper.cpp. Looking for VS bundled cmake..."
    }
}
if (-not $cmakeExe) {
    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $vsInstall = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.CMake.Project -property installationPath 2>$null
        if ($vsInstall) {
            $candidate = Join-Path $vsInstall 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
            if (Test-Path $candidate) { $cmakeExe = $candidate }
        }
    }
}
if (-not $cmakeExe) { throw "cmake not found. Install: winget install Kitware.CMake --version 3.31.7" }
Write-Host "cmake: $cmakeExe" -ForegroundColor DarkGray

# --- clean build dir ---
$build = Join-Path $src "build"
if (Test-Path $build) { Remove-Item -Recurse -Force $build }

# --- configure & build ---
Push-Location $src
try {
    if ($CpuOnly) {
        Write-Host "Building whisper.cpp (CPU-only)..." -ForegroundColor Cyan
        & $cmakeExe -B build -G "Visual Studio 17 2022" `
            -DWHISPER_CUDA=OFF `
            -DWHISPER_BUILD_TESTS=OFF `
            -DWHISPER_BUILD_EXAMPLES=ON
    } else {
        Write-Host "Building whisper.cpp (CUDA)..." -ForegroundColor Cyan
        $gpuInfo = Get-GpuArch
        $arch    = if ($gpuInfo) { $gpuInfo.CudaArch } else { 120 }
        $CudaRoot = Get-BestCudaRoot -CudaArch $arch
        if (-not $CudaRoot) {
            Write-Warning "CUDA toolkit not found — falling back to CPU-only build."
            & $cmakeExe -B build -G "Visual Studio 17 2022" `
                -DWHISPER_CUDA=OFF `
                -DWHISPER_BUILD_TESTS=OFF `
                -DWHISPER_BUILD_EXAMPLES=ON
        } else {
            $env:CUDA_PATH = $CudaRoot
            & $cmakeExe -B build -G "Visual Studio 17 2022" `
                -DWHISPER_CUDA=ON `
                -DCMAKE_CUDA_ARCHITECTURES="$arch" `
                -DCUDAToolkit_ROOT="$CudaRoot" `
                -DWHISPER_BUILD_TESTS=OFF `
                -DWHISPER_BUILD_EXAMPLES=ON
        }
    }
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $cmakeExe --build build --config Release -j
    if ($LASTEXITCODE -ne 0) { throw "cmake build failed" }
    Write-Host "Build succeeded in $([int]$sw.Elapsed.TotalMinutes)m$($sw.Elapsed.Seconds)s." -ForegroundColor Green
} finally { Pop-Location }

# --- stage into _build_tmp\, then atomic-swap into bin/ ---
$tmp = Join-Path $bin "_build_tmp_whisper"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    # whisper.cpp places binaries in build\bin\Release\ (same as llama.cpp)
    $releaseBin = Join-Path $build "bin\Release"
    if (Test-Path $releaseBin) {
        Copy-Item (Join-Path $releaseBin "*") $tmp -Force
    } else {
        # fallback: search for whisper-server.exe anywhere under build
        $found = Get-ChildItem $build -Recurse -Filter "whisper-server.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            Copy-Item (Join-Path $found.DirectoryName "*") $tmp -Force
        } else {
            throw "whisper-server.exe not found in build output — build may have failed silently"
        }
    }

    if (-not (Test-Path (Join-Path $tmp "whisper-server.exe"))) {
        throw "whisper-server.exe missing from staged output — aborting"
    }
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    if (Test-Path $serverExe) { Move-Item $serverExe "$serverExe.bak" -Force }

    # Copy files one-by-one: exes always, DLLs only if not already present.
    # whisper.cpp and llama.cpp share GGML DLLs — don't overwrite locked ones.
    foreach ($f in Get-ChildItem $tmp) {
        $dest = Join-Path $bin $f.Name
        if ($f.Extension -eq '.dll' -and (Test-Path $dest)) {
            # Skip: compatible DLL already in bin/ (possibly loaded by running process)
            continue
        }
        try { Copy-Item $f.FullName $dest -Force }
        catch {
            if ($f.Extension -eq '.dll') {
                Write-Warning "Skipped locked DLL: $($f.Name) — already in bin/ from llama.cpp build"
            } else { throw }
        }
    }
} catch {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    throw
}
Remove-Item -Recurse -Force $tmp

Write-Host "Built. whisper-server at: $bin\whisper-server.exe" -ForegroundColor Green
& $serverExe --version
