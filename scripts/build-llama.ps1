#requires -Version 7
# Build llama.cpp for any NVIDIA GPU. Auto-detects architecture and CUDA root from nvidia-smi.
#   -Arch <int>       CMake CUDA architecture (e.g. 89 for Ada, 86 for Ampere, 120 for Blackwell).
#                     Omit to auto-detect via nvidia-smi (falls back to 120 if undetectable).
#   -CudaRoot <path>  Path to the CUDA toolkit root. Omit to auto-select for the detected arch.
#   -Force            Rebuild even if bin\llama-server.exe already exists.
param([int]$Arch = 0, [string]$CudaRoot = '', [switch]$Force)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$src  = Join-Path $repo "external\llama.cpp"
$bin  = Join-Path $repo "bin"
. "$PSScriptRoot\_models.ps1"

if (-not $Force -and (Test-Path (Join-Path $bin "llama-server.exe"))) {
  Write-Host "llama-server.exe already built — skipping (use -Force to rebuild)." -ForegroundColor DarkGray
  return
}

if (-not (Test-Path (Join-Path $src "CMakeLists.txt"))) {
  throw "llama.cpp submodule not found at $src. Run: git submodule update --init --recursive"
}

# --- resolve architecture ---
if ($Arch -eq 0) {
  $gpuInfo = Get-GpuArch
  if ($gpuInfo) {
    $Arch = $gpuInfo.CudaArch
    Write-Host "Detected GPU: $($gpuInfo.Gen) (sm_$Arch)" -ForegroundColor Cyan
  } else {
    Write-Warning "Could not detect GPU via nvidia-smi. Defaulting to sm_120 (Blackwell). Pass -Arch to override."
    $Arch = 120
  }
}

# --- resolve CUDA root ---
if (-not $CudaRoot) {
  $CudaRoot = Get-BestCudaRoot -CudaArch $Arch
  if (-not $CudaRoot) {
    if ($Arch -ge 120) {
      throw "CUDA Toolkit 12.8 not found. Required for Blackwell (sm_120). Install: winget install Nvidia.CUDA --version 12.8"
    } else {
      throw "No compatible CUDA toolkit found for sm_$Arch. Install CUDA 12.x: winget install Nvidia.CUDA"
    }
  }
}

# Blackwell with a non-12.8 toolkit still builds, but the MMQ fast path won't activate.
if ($Arch -ge 120 -and $CudaRoot -notmatch 'v12\.8') {
  Write-Warning "Blackwell (sm_120) needs CUDA 12.8 for the fast MMQ path. Toolkit: $CudaRoot. Prefill may be ~5x slower."
}

Write-Host "Architecture : sm_$Arch" -ForegroundColor Cyan
Write-Host "CUDA toolkit : $CudaRoot" -ForegroundColor Cyan

# Set env vars the VS build system uses to locate the toolkit (winget installs don't always set these).
$env:CUDA_PATH = $CudaRoot
$verTag = (Split-Path $CudaRoot -Leaf) -replace '^v', '' -replace '\.', '_'   # "12.8" -> "12_8"
Set-Item "env:CUDA_PATH_V$verTag" $CudaRoot

# DLL major version for staging (cublas64_12.dll vs cublas64_11.dll etc.)
$cudaMajor = if ((Split-Path $CudaRoot -Leaf) -match '^v(\d+)') { $Matches[1] } else { '12' }

# --- clean build dir (stale cache can silently force the slow cuBLAS path) ---
$build = Join-Path $src "build"
if (Test-Path $build) { Remove-Item -Recurse -Force $build }

# llama.cpp's cmake_minimum_required(3.14...3.28) excludes cmake 4.x, causing CUDA architecture
# validation failures. Check PATH cmake version first; only fall back to VS's bundled cmake if
# PATH cmake is 4.x (e.g. the Python scoop package installs cmake 4.x).
$cmakeExe = $null
$pathCmake = Get-Command cmake -ErrorAction SilentlyContinue
if ($pathCmake) {
    $cmakeVer = (& cmake --version 2>&1 | Select-Object -First 1) -replace 'cmake version\s+', ''
    if ([version]$cmakeVer -lt [version]'4.0') {
        $cmakeExe = 'cmake'
    } else {
        Write-Warning "PATH cmake is $cmakeVer (4.x) — incompatible with llama.cpp. Looking for VS bundled cmake..."
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
if (-not $cmakeExe) {
    # scoop cmake tracks latest (4.x) — use winget to install a pinned 3.x build instead
    Write-Host "Installing cmake 3.31.7 via winget..." -ForegroundColor Cyan
    winget install Kitware.CMake --version 3.31.7 --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "cmake install failed. Fix manually: winget install Kitware.CMake --version 3.31.7"
    }
    # Refresh PATH so the newly installed cmake is visible in this process
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    $cmakeExe = (Get-Command cmake -ErrorAction SilentlyContinue)?.Source
    if (-not $cmakeExe) { throw "cmake still not found after install — open a new terminal and retry." }
}
Write-Host "cmake       : $cmakeExe" -ForegroundColor DarkGray

# Add -DCMAKE_CUDA_FLAGS="-allow-unsupported-compiler" below if nvcc rejects your MSVC version.
Push-Location $src
try {
  & $cmakeExe -B build -G "Visual Studio 17 2022" -T "cuda=$CudaRoot" `
    -DGGML_CUDA=ON `
    -DCMAKE_CUDA_ARCHITECTURES="$Arch" `
    -DGGML_CUDA_FORCE_CUBLAS=OFF `
    -DCUDAToolkit_ROOT="$CudaRoot"
  if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }

  & $cmakeExe --build build --config Release -j
  if ($LASTEXITCODE -ne 0) { throw "cmake build failed" }
} finally { Pop-Location }

# --- stage into _build_tmp\, then atomic-swap into bin/ on success ---
$tmp = Join-Path $bin "_build_tmp"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
  Copy-Item (Join-Path $build "bin\Release\*") $tmp -Force
  # CUDA runtime DLLs are not statically linked — copy them so bin/ runs without CUDA on PATH.
  foreach ($d in "cublas64_$cudaMajor.dll", "cublasLt64_$cudaMajor.dll", "cudart64_$cudaMajor.dll") {
    Copy-Item (Join-Path $CudaRoot "bin\$d") $tmp -Force -ErrorAction SilentlyContinue
  }
  if (-not (Test-Path (Join-Path $tmp "llama-server.exe"))) {
    throw "llama-server.exe missing from staged output — aborting swap"
  }
  New-Item -ItemType Directory -Force -Path $bin | Out-Null
  $svr = Join-Path $bin "llama-server.exe"
  if (Test-Path $svr) { Move-Item $svr "$svr.bak" -Force }
  Copy-Item (Join-Path $tmp "*") $bin -Force
} catch {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  throw
}
Remove-Item -Recurse -Force $tmp

Write-Host "Built. llama-server at: $bin\llama-server.exe" -ForegroundColor Green
& (Join-Path $bin "llama-server.exe") --version
