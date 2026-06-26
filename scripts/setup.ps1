#requires -Version 7
# Master setup orchestrator (invoked by setup.bat). Idempotent; safe to re-run.
#   .\scripts\setup.ps1                        # full
#   .\scripts\setup.ps1 -SkipModels            # skip the ~38GB model downloads
#   .\scripts\setup.ps1 -SkipModels -SkipBuild # skip models + binary compilation (venvs + config only)
#   .\scripts\setup.ps1 -Profile 12gb          # smaller models for ~12GB VRAM (see config/models.psd1)
#   .\scripts\setup.ps1 -Launch                # start the stack (up.ps1) when finished
param([switch]$SkipModels, [switch]$SkipBuild, [switch]$Launch, [string]$Profile)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\_models.ps1"
function Have($n){ [bool](Get-Command $n -ErrorAction SilentlyContinue) }
function Step($m){ Write-Host "`n==== $m ====" -ForegroundColor Cyan }
function Install-WithWinget {
  param([string]$Package, [string[]]$ExtraArgs = @())
  winget install $Package @ExtraArgs `
    --accept-package-agreements --accept-source-agreements --disable-interactivity
  # -1978335189 (0x8A150011 as signed int32) = APPINSTALLER_CLI_ERROR_PACKAGE_ALREADY_INSTALLED
  if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
    throw "winget install $Package failed (exit $LASTEXITCODE)"
  }
}

Step "System check"
& "$PSScriptRoot\diagnose.ps1"

Step "Core tooling"
if (-not (Have git))   { throw "git not found. Install Git, then re-run setup.bat." }
if (-not (Have scoop)) { throw "scoop not found. Install it:  irm get.scoop.sh | iex   then re-run setup.bat." }
Write-Host "git ok; scoop ok"

Step "Prereqs: Node.js + uv (Continue MCP servers + fabric)"
if (Have node) { Write-Host "node ok" } else { Install-WithWinget 'OpenJS.NodeJS' }
if (Have uvx)  { Write-Host "uv ok"   } else { Install-WithWinget 'astral-sh.uv'  }

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
    Install-WithWinget 'Nvidia.CUDA' @('--version','12.8')
  } else {
    Write-Warning "winget not found — install CUDA Toolkit 12.8 manually for Blackwell, then re-run."
  }
} elseif ($gpuInfo) {
  # Ada / Ampere: any CUDA 12.x works.
  if ($cudaRoot) {
    Write-Host "CUDA ok: $cudaRoot ($($gpuInfo.Gen))"
  } elseif (Have winget) {
    Write-Host "No CUDA 12.x found for $($gpuInfo.Gen). Installing CUDA 12.8..." -ForegroundColor Yellow
    Install-WithWinget 'Nvidia.CUDA' @('--version','12.8')
  } else {
    Write-Warning "No compatible CUDA found. Install CUDA 12.x manually, then re-run."
  }
} else {
  # Could not detect GPU — fall back to original behavior (install 12.8).
  if (Test-Path "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.8") {
    Write-Host "CUDA 12.8 ok"
  } elseif (Have winget) {
    Write-Host "Installing CUDA Toolkit 12.8..." -ForegroundColor Yellow
    Install-WithWinget 'Nvidia.CUDA' @('--version','12.8')
  } else {
    Write-Warning "winget not found — install CUDA Toolkit 12.8 manually, then re-run."
  }
}

$vswhereExe = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'

Step "Prereq: VS2022 C++ toolchain (MSVC required for llama.cpp build)"
$serverExe = Join-Path $repo 'bin\llama-server.exe'
if (-not $SkipBuild -and -not (Test-Path $serverExe)) {
    $vsInstall = if (Test-Path $vswhereExe) {
        & $vswhereExe -latest -products * -requires Microsoft.VisualStudio.Workload.NativeDesktop -property installationPath 2>$null
    }
    if ($vsInstall) {
        Write-Host "MSVC ok" -ForegroundColor DarkGray
    } else {
        throw @"
VS2022 'Desktop development with C++' workload not found — required to compile llama.cpp.
  Install VS2022:  winget install Microsoft.VisualStudio.2022.Community
  Then open VS Installer -> Modify -> add workload: 'Desktop development with C++'
  Re-run setup.bat when done.  (Pass -SkipBuild if you have a prebuilt bin\llama-server.exe.)
"@
    }
} else {
    Write-Host "MSVC check skipped (build not needed)" -ForegroundColor DarkGray
}

Step "Prereq: cmake 3.x (cmake 4.x excluded by llama.cpp version range)"
$cmakeOk = $false
$pathCmakeCmd = Get-Command cmake -ErrorAction SilentlyContinue
if ($pathCmakeCmd) {
    $cmakeVer = (& cmake --version 2>&1 | Select-Object -First 1) -replace 'cmake version\s+', ''
    if ([version]$cmakeVer -lt [version]'4.0') {
        $cmakeOk = $true
        Write-Host "cmake ok ($cmakeVer)" -ForegroundColor DarkGray
    } else {
        Write-Host "PATH cmake is $cmakeVer (4.x) — checking VS bundled cmake..." -ForegroundColor Yellow
    }
}
if (-not $cmakeOk -and (Test-Path $vswhereExe)) {
    $vsI = & $vswhereExe -latest -products * -requires Microsoft.VisualStudio.Component.VC.CMake.Project -property installationPath 2>$null
    if ($vsI -and (Test-Path (Join-Path $vsI 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'))) {
        $cmakeOk = $true
        Write-Host "cmake ok (VS bundled 3.31.x)" -ForegroundColor DarkGray
    }
}
if (-not $cmakeOk) {
    Write-Host "Installing cmake 3.31.7 via winget..." -ForegroundColor Cyan
    Install-WithWinget 'Kitware.CMake' @('--version', '3.31.7')
    # cmake will be on PATH after the $env:PATH refresh below
}

# Refresh PATH so shims from packages just installed by scoop/winget are visible to bootstrap.
$env:PATH = [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH','User')

Step "Bootstrap: submodules -> build engine+proxy -> venvs+tools -> models"
$ba = @{}
if ($SkipModels) { $ba['SkipModels'] = $true }
if ($SkipBuild)  { $ba['SkipBuild']  = $true }
if ($Profile)    { $ba['Profile']    = $Profile }
& "$PSScriptRoot\bootstrap.ps1" @ba

Step "Wire clients (Continue + aider)"
& "$PSScriptRoot\setup-clients.ps1"

Step "fabric (shell AI patterns)"
& "$PSScriptRoot\setup-fabric.ps1"

Step "Install 'llm' CLI command"
& "$PSScriptRoot\install-cli.ps1"

Step "All set"
Write-Host "Open a new terminal, then:  llm up   (or  llm help  for all commands)" -ForegroundColor Green
if ($Launch) { & "$PSScriptRoot\up.ps1" }
