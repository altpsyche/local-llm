#requires -Version 7
# Build llama.cpp submodule for Blackwell (sm_120) with CUDA 12.8. Copies binaries to bin/.
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$src  = Join-Path $repo "external\llama.cpp"
$bin  = Join-Path $repo "bin"

if (-not (Test-Path (Join-Path $src "CMakeLists.txt"))) {
  throw "llama.cpp submodule not found at $src. Run: git submodule update --init --recursive"
}

# --- locate CUDA 12.8 (must be 12.8, NOT 13.x — 13.x breaks Blackwell MMQ) ---
$cudaRoot = "C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v12.8"
if (-not (Test-Path $cudaRoot)) {
  throw "CUDA Toolkit 12.8 not found at $cudaRoot. Install it (toolkit only) before building. Do NOT use 13.x."
}
Write-Host "Using CUDA toolkit: $cudaRoot" -ForegroundColor Cyan

# The VS generator's MSBuild CUDA integration resolves the toolkit via these env vars / the -T toolset.
# winget doesn't always set them in the current shell, so set them explicitly.
$env:CUDA_PATH      = $cudaRoot
$env:CUDA_PATH_V12_8 = $cudaRoot

# --- clean build dir (stale cache can silently force the slow cuBLAS path) ---
$build = Join-Path $src "build"
if (Test-Path $build) { Remove-Item -Recurse -Force $build }

# Add -DCMAKE_CUDA_FLAGS="-allow-unsupported-compiler" below if nvcc rejects your MSVC version.
Push-Location $src
try {
  # If CMake 4.x ever rejects llama.cpp's cmake_minimum_required, add this as ONE quoted token:
  #   '-DCMAKE_POLICY_VERSION_MINIMUM=3.5'   (quote it — PowerShell otherwise splits 3.5 into 3 + .5)
  cmake -B build -G "Visual Studio 17 2022" -T "cuda=$cudaRoot" `
    -DGGML_CUDA=ON `
    -DCMAKE_CUDA_ARCHITECTURES=120 `
    -DGGML_CUDA_FORCE_CUBLAS=OFF `
    -DCUDAToolkit_ROOT="$cudaRoot"
  if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }

  cmake --build build --config Release -j
  if ($LASTEXITCODE -ne 0) { throw "cmake build failed" }
} finally { Pop-Location }

# --- stage binaries + DLLs into bin/ ---
New-Item -ItemType Directory -Force -Path $bin | Out-Null
Copy-Item (Join-Path $build "bin\Release\*") $bin -Force
# CUDA runtime DLLs are NOT static — copy them so bin/ runs without CUDA on PATH
foreach ($d in "cublas64_12.dll","cublasLt64_12.dll","cudart64_12.dll") {
  Copy-Item (Join-Path $cudaRoot "bin\$d") $bin -Force -ErrorAction SilentlyContinue
}
Write-Host "Built. llama-server at: $bin\llama-server.exe" -ForegroundColor Green
& (Join-Path $bin "llama-server.exe") --version
