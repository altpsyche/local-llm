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

# Add -DCMAKE_CUDA_FLAGS="-allow-unsupported-compiler" below if nvcc rejects your MSVC version.
# Add -DCMAKE_POLICY_VERSION_MINIMUM=3.5 (as ONE quoted token) if CMake 4.x rejects cmake_minimum_required.
Push-Location $src
try {
  cmake -B build -G "Visual Studio 17 2022" -T "cuda=$CudaRoot" `
    -DGGML_CUDA=ON `
    -DCMAKE_CUDA_ARCHITECTURES=$Arch `
    -DGGML_CUDA_FORCE_CUBLAS=OFF `
    -DCUDAToolkit_ROOT="$CudaRoot"
  if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }

  cmake --build build --config Release -j
  if ($LASTEXITCODE -ne 0) { throw "cmake build failed" }
} finally { Pop-Location }

# --- stage binaries + DLLs into bin/ ---
New-Item -ItemType Directory -Force -Path $bin | Out-Null
Copy-Item (Join-Path $build "bin\Release\*") $bin -Force
# CUDA runtime DLLs are not statically linked — copy them so bin/ runs without CUDA on PATH.
foreach ($d in "cublas64_$cudaMajor.dll", "cublasLt64_$cudaMajor.dll", "cudart64_$cudaMajor.dll") {
  Copy-Item (Join-Path $CudaRoot "bin\$d") $bin -Force -ErrorAction SilentlyContinue
}
Write-Host "Built. llama-server at: $bin\llama-server.exe" -ForegroundColor Green
& (Join-Path $bin "llama-server.exe") --version
