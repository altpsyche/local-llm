#requires -Version 7
# Master setup orchestrator (invoked by setup.bat). Idempotent; safe to re-run.
# Prerequisites must be installed first via install_prereqs.bat.
#
#   .\scripts\setup.ps1                        # full
#   .\scripts\setup.ps1 -SkipModels            # skip the ~38GB model downloads
#   .\scripts\setup.ps1 -SkipModels -SkipBuild # skip models + binary compilation (venvs + config only)
#   .\scripts\setup.ps1 -Profile 12gb          # smaller models for ~12GB VRAM (see config/models.psd1)
#   .\scripts\setup.ps1 -Launch                # start the stack (up.ps1) when finished
param([switch]$SkipModels, [switch]$SkipBuild, [switch]$Launch, [string]$Profile)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\_models.ps1"
. "$PSScriptRoot\_common.ps1"   # Have, Install-WithWinget

$script:stepTotal   = 10
$script:stepCurrent = 0
$script:stepSw      = $null
$setupStart         = [Diagnostics.Stopwatch]::StartNew()

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

Step "System check"
& "$PSScriptRoot\diagnose.ps1"

Step "Core tooling"
if (-not (Have git))   { throw "git not found. Install Git, then re-run setup.bat." }
if (-not (Have scoop)) { throw "scoop not found. Install it:  irm get.scoop.sh | iex   then re-run setup.bat." }
Write-Host "git ok; scoop ok"

Step "Prerequisite check"
$missing = @()
if (-not (Have 'node'))  { $missing += 'Node.js' }
if (-not (Have 'go'))    { $missing += 'Go' }
if (-not (Have 'uvx'))   { $missing += 'uv' }
$hasPy = $false; try { scoop prefix python312 *>$null; $hasPy = ($LASTEXITCODE -eq 0) } catch {}
if (-not $hasPy)         { $missing += 'Python 3.12' }
if ($missing) {
    Write-Host "`nMissing prerequisites: $($missing -join ', ')" -ForegroundColor Red
    Write-Host "Run install_prereqs.bat first, then re-run setup.bat." -ForegroundColor Yellow
    exit 1
}
Write-Host "  Prerequisites ok." -ForegroundColor DarkGray

# Refresh PATH so shims installed by scoop/winget are visible to bootstrap.
$env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH', 'User')

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
}

Step "Bootstrap: submodules -> build engine+proxy -> venvs+tools -> models" "first build takes 5-15 min"
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

Step "Docker services (Langfuse + SearXNG + n8n)"
$dockerExe = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
if ((Have 'docker') -or (Test-Path $dockerExe)) {
    & "$PSScriptRoot\setup-docker.ps1"
} else {
    Write-Host "  Docker not installed — skipping Docker services." -ForegroundColor DarkGray
    Write-Host "  To add later: run install_prereqs.bat, then re-run setup.bat." -ForegroundColor DarkGray
}

if ($script:stepSw) { Write-Host "    done in $([int]$script:stepSw.Elapsed.TotalSeconds)s" -ForegroundColor DarkGray }
Write-Host "`nSetup complete in $([int]$setupStart.Elapsed.TotalMinutes)m$($setupStart.Elapsed.Seconds)s." -ForegroundColor Green
Write-Host "Open a new terminal, then:  llm up   (or  llm help  for all commands)" -ForegroundColor Green
if ($Launch) { & "$PSScriptRoot\up.ps1" }
