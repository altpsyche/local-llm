#requires -Version 7
# Master setup orchestrator (invoked by setup.bat). Idempotent; safe to re-run.
#   .\scripts\setup.ps1                # full
#   .\scripts\setup.ps1 -SkipModels    # skip the ~38GB model downloads
#   .\scripts\setup.ps1 -Profile 12gb  # smaller models for ~12GB VRAM (see config/models.psd1)
#   .\scripts\setup.ps1 -Launch        # start the stack (up.ps1) when finished
param([switch]$SkipModels, [switch]$Launch, [string]$Profile)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\_models.ps1"
function Have($n){ [bool](Get-Command $n -ErrorAction SilentlyContinue) }
function Step($m){ Write-Host "`n==== $m ====" -ForegroundColor Cyan }

Step "System check"
& "$PSScriptRoot\diagnose.ps1"

Step "Core tooling"
if (-not (Have git))   { throw "git not found. Install Git, then re-run setup.bat." }
if (-not (Have scoop)) { throw "scoop not found. Install it:  irm get.scoop.sh | iex   then re-run setup.bat." }
Write-Host "git ok; scoop ok"

Step "Prereqs: Go + Python 3.12 (scoop)"
if (Have go) { Write-Host "go ok" } else { scoop install go }
$hasPy = $false; try { scoop prefix python312 *> $null; $hasPy = ($LASTEXITCODE -eq 0) } catch {}
if ($hasPy) { Write-Host "python312 ok" } else { scoop install python312 }

Step "Prereq: CUDA Toolkit"
$gpuInfo  = Get-GpuArch
$cudaRoot = if ($gpuInfo) { Get-BestCudaRoot -CudaArch $gpuInfo.CudaArch } else { $null }

if ($gpuInfo) { Write-Host "Detected GPU: $($gpuInfo.Gen) (sm_$($gpuInfo.CudaArch))" -ForegroundColor Cyan }

if ($gpuInfo -and $gpuInfo.CudaArch -ge 120) {
  # Blackwell requires CUDA 12.8 for the MMQ fast path — install it if missing.
  if ($cudaRoot) {
    Write-Host "CUDA 12.8 ok (Blackwell)"
  } elseif (Have winget) {
    Write-Host "Installing CUDA Toolkit 12.8 (required for Blackwell, large download)..." -ForegroundColor Yellow
    winget install Nvidia.CUDA --version 12.8 --accept-package-agreements --accept-source-agreements --disable-interactivity
  } else {
    Write-Warning "winget not found — install CUDA Toolkit 12.8 manually for Blackwell, then re-run."
  }
} elseif ($gpuInfo) {
  # Ada / Ampere: any CUDA 12.x works.
  if ($cudaRoot) {
    Write-Host "CUDA ok: $cudaRoot ($($gpuInfo.Gen))"
  } elseif (Have winget) {
    Write-Host "No CUDA 12.x found for $($gpuInfo.Gen). Installing CUDA 12.8..." -ForegroundColor Yellow
    winget install Nvidia.CUDA --version 12.8 --accept-package-agreements --accept-source-agreements --disable-interactivity
  } else {
    Write-Warning "No compatible CUDA found. Install CUDA 12.x manually, then re-run."
  }
} else {
  # Could not detect GPU — fall back to original behavior (install 12.8).
  if (Test-Path "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.8") {
    Write-Host "CUDA 12.8 ok"
  } elseif (Have winget) {
    Write-Host "Installing CUDA Toolkit 12.8..." -ForegroundColor Yellow
    winget install Nvidia.CUDA --version 12.8 --accept-package-agreements --accept-source-agreements --disable-interactivity
  } else {
    Write-Warning "winget not found — install CUDA Toolkit 12.8 manually, then re-run."
  }
}

# Refresh PATH so shims from packages just installed by scoop (go, python312) are visible
# to bootstrap in THIS session — otherwise a fresh machine may "miss" go and skip the proxy build.
$env:PATH = [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH','User')

Step "Bootstrap: submodules -> build engine+proxy -> venvs+tools -> models"
$ba = @(); if ($SkipModels) { $ba += '-SkipModels' }
if ($Profile) { $ba += @('-Profile', $Profile) }
& "$PSScriptRoot\bootstrap.ps1" @ba

Step "Wire clients (Continue + aider)"
& "$PSScriptRoot\setup-clients.ps1"

Step "Install 'llm' CLI command"
& "$PSScriptRoot\install-cli.ps1"

Step "All set"
Write-Host "Open a new terminal, then:  llm up   (or  llm help  for all commands)" -ForegroundColor Green
if ($Launch) { & "$PSScriptRoot\up.ps1" }
