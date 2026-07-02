#requires -Version 7
# Install all prerequisites for bob (Node.js, uv, Go, Python 3.12, CUDA, cmake,
# Docker Desktop). Run once on a fresh machine. Idempotent — safe to re-run.
# Windows uses winget/scoop; Linux (NC2) uses apt/dnf/pacman via the Install-Package seam.
#   -Cpu   Skip the CUDA toolkit (CPU-only tier). CUDA becomes optional.
#
# When done, one of two messages will appear:
#   - "All prerequisites verified. Run setup.bat now."   (Docker was already installed)
#   - "Log out and back in, then run: setup.bat"          (Docker was just installed)
param([switch]$Cpu)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\_common.ps1"   # Have, Install-WithWinget
. "$PSScriptRoot\_models.ps1"   # Get-GpuArch, Get-BestCudaRoot, + NC1 seam (_platform.ps1)

# ── NC2 — Linux prereq bootstrap (apt/dnf/pacman via Install-Package). The .sh installs pwsh, then
#    hands off here; the toolchain install is genuinely OS-specific (not shared logic to duplicate). ──
function Install-LinuxPrereqs {
    param([switch]$Cpu)
    $mgr = Get-LinuxPackageManager
    if (-not $mgr) { throw "No supported package manager (apt/dnf/pacman) found. Install the toolchain manually — see docs/MANUAL-INSTALL.md." }
    Write-Host "=== Linux prerequisites ($mgr) ===" -ForegroundColor Cyan

    # Toolchain package names per manager (git/curl/compiler/cmake/ninja/go/node/python+venv).
    $pkgs = switch ($mgr) {
        'apt'    { @('git', 'curl', 'build-essential', 'cmake', 'ninja-build', 'golang-go', 'nodejs', 'npm', 'python3', 'python3-venv', 'python3-pip') }
        'dnf'    { @('git', 'curl', 'gcc-c++', 'make', 'cmake', 'ninja-build', 'golang', 'nodejs', 'npm', 'python3', 'python3-pip') }
        'pacman' { @('git', 'curl', 'base-devel', 'cmake', 'ninja', 'go', 'nodejs', 'npm', 'python') }
    }
    foreach ($p in $pkgs) {
        Write-Host "  install $p ..." -ForegroundColor DarkGray
        try { Install-Package -Package $p } catch { Write-Warning "  $p failed: $_ (install it manually and re-run)" }
    }

    # Python 3.12+ is required by bootstrap.ps1. Distros vary; warn (don't fail) if the default is older.
    $pyv = try { (& python3 --version 2>&1) -replace 'Python\s+', '' } catch { $null }
    if ($pyv -and [version]($pyv -replace '(\d+\.\d+).*', '$1') -lt [version]'3.12') {
        Write-Warning "python3 is $pyv — Bob needs 3.12+. Install it (e.g. deadsnakes PPA on Ubuntu) and ensure it's on PATH."
    }

    if ($Cpu) {
        Write-Host "  -Cpu: skipping CUDA toolkit (CPU-only tier)." -ForegroundColor DarkGray
    } elseif (Have 'nvidia-smi') {
        if (Have 'nvcc') {
            Write-Host "  CUDA toolkit (nvcc) ok" -ForegroundColor DarkGray
        } else {
            Write-Warning @"
  NVIDIA GPU detected but nvcc (CUDA toolkit) is not on PATH.
  Install the CUDA toolkit for your distro (https://developer.nvidia.com/cuda-downloads),
  or run the CPU tier: ./install_prereqs.sh --cpu && ./setup.sh
"@
        }
    } else {
        Write-Host "  No NVIDIA GPU (nvidia-smi absent) — CPU tier. Skipping CUDA." -ForegroundColor DarkGray
    }

    # Docker is optional (compose services); already cross-platform where present.
    if (Have 'docker') { Write-Host "  docker ok" -ForegroundColor DarkGray }
    else { Write-Host "  docker not found (optional — needed only for the compose services). Install docker + add your user to the docker group." -ForegroundColor DarkGray }

    Write-Host "`nLinux prerequisites done. Run: ./setup.sh$(if ($Cpu) { ' --cpu' })" -ForegroundColor Green
}

if ((Get-BobOS) -ne 'windows') { Install-LinuxPrereqs -Cpu:$Cpu; return }

$script:stepTotal   = 7
$script:stepCurrent = 0
$script:stepSw      = $null

function Step {
    param([string]$Name, [string]$Hint = '')
    if ($script:stepCurrent -gt 0 -and $script:stepSw) {
        Write-Host "    done in $([int]$script:stepSw.Elapsed.TotalSeconds)s" -ForegroundColor DarkGray
    }
    $script:stepCurrent++
    $script:stepSw = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "`n=== Step $script:stepCurrent/$script:stepTotal: $Name ===" -ForegroundColor Cyan
    if ($Hint) { Write-Host "  ($Hint)" -ForegroundColor DarkGray }
}

# ---------------------------------------------------------------------------
# 1. Manual prereqs — must exist before this script can help
# ---------------------------------------------------------------------------
Step "Manual prerequisites"
if (-not (Have 'git')) {
    throw "git not found. Install Git from https://git-scm.com, then re-run install_prereqs.bat."
}
if (-not (Have 'scoop')) {
    throw "scoop not found. Install it:  irm get.scoop.sh | iex   then re-run install_prereqs.bat."
}
Write-Host "  git ok; scoop ok" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 2. VS2022 with Desktop C++ workload
# ---------------------------------------------------------------------------
Step "VS2022 C++ toolchain"
$vswhereExe = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$vsInstall = if (Test-Path $vswhereExe) {
    & $vswhereExe -latest -products * -requires Microsoft.VisualStudio.Workload.NativeDesktop -property installationPath 2>$null
}
if ($vsInstall) {
    Write-Host "  VS2022 ok" -ForegroundColor DarkGray
} else {
    throw @"
VS2022 'Desktop development with C++' workload not found — required to compile llama.cpp.
  Install VS2022:  winget install Microsoft.VisualStudio.2022.Community
  Then open VS Installer -> Modify -> add workload: 'Desktop development with C++'
  Re-run install_prereqs.bat when done.  (Pass -SkipBuild to setup.bat if you have a prebuilt bin\llama-server.exe.)
"@
}

# ---------------------------------------------------------------------------
# 3. Node.js + uv  (Continue MCP servers + fabric)
# ---------------------------------------------------------------------------
Step "Node.js + uv"
if (Have 'node') { Write-Host "  node ok" -ForegroundColor DarkGray } else { Install-WithWinget 'OpenJS.NodeJS' }
if (Have 'uvx')  { Write-Host "  uv ok"   -ForegroundColor DarkGray } else { Install-WithWinget 'astral-sh.uv'  }

# ---------------------------------------------------------------------------
# 4. Go + Python 3.12  (scoop)
# ---------------------------------------------------------------------------
Step "Go + Python 3.12"
if (Have 'go') { Write-Host "  go ok" -ForegroundColor DarkGray } else { scoop install go }
$hasPy = $false; try { scoop prefix python312 *>$null; $hasPy = ($LASTEXITCODE -eq 0) } catch {}
if ($hasPy) { Write-Host "  python312 ok" -ForegroundColor DarkGray } else { scoop install python312 }

# ---------------------------------------------------------------------------
# 5. CUDA Toolkit  (GPU-aware)
# ---------------------------------------------------------------------------
Step "CUDA Toolkit"
$gpuInfo  = Get-GpuArch
$cudaRoot = if ($gpuInfo) { Get-BestCudaRoot -CudaArch $gpuInfo.CudaArch } else { $null }

if ($gpuInfo) { Write-Host "  Detected GPU: $($gpuInfo.Gen) (sm_$($gpuInfo.CudaArch))" -ForegroundColor DarkGray }

if ($gpuInfo -and $gpuInfo.CudaArch -ge 120) {
    if ($cudaRoot) {
        Write-Host "  CUDA 12.8 ok (Blackwell)" -ForegroundColor DarkGray
    } elseif (Have 'winget') {
        Write-Host "  Installing CUDA Toolkit 12.8 (required for Blackwell, large download)..." -ForegroundColor Yellow
        Install-WithWinget 'Nvidia.CUDA' @('--version', '12.8')
    } else {
        Write-Warning "winget not found — install CUDA Toolkit 12.8 manually for Blackwell, then re-run."
    }
} elseif ($gpuInfo) {
    if ($cudaRoot) {
        Write-Host "  CUDA ok: $cudaRoot ($($gpuInfo.Gen))" -ForegroundColor DarkGray
    } elseif (Have 'winget') {
        Write-Host "  No CUDA 12.x found for $($gpuInfo.Gen). Installing CUDA 12.8..." -ForegroundColor Yellow
        Install-WithWinget 'Nvidia.CUDA' @('--version', '12.8')
    } else {
        Write-Warning "No compatible CUDA found. Install CUDA 12.x manually, then re-run."
    }
} else {
    if (Get-CudaRoot -CudaArch 120) {
        Write-Host "  CUDA 12.8 ok" -ForegroundColor DarkGray
    } elseif (Have 'winget') {
        Write-Host "  Installing CUDA Toolkit 12.8..." -ForegroundColor Yellow
        Install-WithWinget 'Nvidia.CUDA' @('--version', '12.8')
    } else {
        Write-Warning "winget not found — install CUDA Toolkit 12.8 manually, then re-run."
    }
}

# ---------------------------------------------------------------------------
# 6. cmake 3.x  (cmake 4.x excluded by llama.cpp version range)
# ---------------------------------------------------------------------------
Step "cmake 3.x"
$cmakeOk = $false
$pathCmakeCmd = Get-Command cmake -ErrorAction SilentlyContinue
if ($pathCmakeCmd) {
    $cmakeVer = (& cmake --version 2>&1 | Select-Object -First 1) -replace 'cmake version\s+', ''
    if ([version]$cmakeVer -lt [version]'4.0') {
        $cmakeOk = $true
        Write-Host "  cmake ok ($cmakeVer)" -ForegroundColor DarkGray
    } else {
        Write-Host "  PATH cmake is $cmakeVer (4.x) — checking VS bundled cmake..." -ForegroundColor Yellow
    }
}
if (-not $cmakeOk -and (Test-Path $vswhereExe)) {
    $vsI = & $vswhereExe -latest -products * -requires Microsoft.VisualStudio.Component.VC.CMake.Project -property installationPath 2>$null
    if ($vsI -and (Test-Path (Join-Path $vsI 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'))) {
        $cmakeOk = $true
        Write-Host "  cmake ok (VS bundled 3.31.x)" -ForegroundColor DarkGray
    }
}
if (-not $cmakeOk) {
    Write-Host "  Installing cmake 3.31.7 via winget..." -ForegroundColor Cyan
    Install-WithWinget 'Kitware.CMake' @('--version', '3.31.7')
}

# ---------------------------------------------------------------------------
# 7. Docker Desktop
# ---------------------------------------------------------------------------
Step "Docker Desktop"
$dockerExe = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
$alreadyHad = (Have 'docker') -or (Test-Path $dockerExe)
if ($alreadyHad) {
    Write-Host "  Docker Desktop ok" -ForegroundColor DarkGray
} else {
    Write-Host "  Installing Docker Desktop..." -ForegroundColor Cyan
    Install-WithWinget 'Docker.DockerDesktop'
}

# ---------------------------------------------------------------------------
# 8. Refresh PATH so shims from packages just installed are visible
# ---------------------------------------------------------------------------
if ($script:stepSw) { Write-Host "    done in $([int]$script:stepSw.Elapsed.TotalSeconds)s" -ForegroundColor DarkGray }
$env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH', 'User')

# ---------------------------------------------------------------------------
# 9. Final message
# ---------------------------------------------------------------------------
Write-Host ""
if ($alreadyHad) {
    Write-Host "All prerequisites verified." -ForegroundColor Green
    Write-Host "Run setup.bat to build and configure the stack." -ForegroundColor Green
} else {
    Write-Host "Docker Desktop installed." -ForegroundColor Green
    Write-Host ""
    Write-Warning @"
ACTION REQUIRED: Log out of Windows and back in, then run:
    setup.bat

This is required because Docker Desktop adds your user to the docker-users
group, and group membership changes only take effect at login.

Note: Before running setup.bat, disable the containerd snapshotter in Docker Desktop:
  Settings -> General -> uncheck "Use containerd for pulling and storing images"
  -> Apply & Restart
This prevents a startup error in SearXNG.
"@
}
