#requires -Version 7
# Master setup orchestrator (invoked by setup.bat). Idempotent; safe to re-run.
#   .\scripts\setup.ps1                # full
#   .\scripts\setup.ps1 -SkipModels    # skip the ~38GB model downloads
#   .\scripts\setup.ps1 -Launch        # start the stack (up.ps1) when finished
param([switch]$SkipModels, [switch]$Launch)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
function Have($n){ [bool](Get-Command $n -ErrorAction SilentlyContinue) }
function Step($m){ Write-Host "`n==== $m ====" -ForegroundColor Cyan }

Step "Core tooling"
if (-not (Have git))   { throw "git not found. Install Git, then re-run setup.bat." }
if (-not (Have scoop)) { throw "scoop not found. Install it:  irm get.scoop.sh | iex   then re-run setup.bat." }
Write-Host "git ok; scoop ok"

Step "Prereqs: Go + Python 3.12 (scoop)"
if (Have go) { Write-Host "go ok" } else { scoop install go }
$hasPy = $false; try { scoop prefix python312 *> $null; $hasPy = ($LASTEXITCODE -eq 0) } catch {}
if ($hasPy) { Write-Host "python312 ok" } else { scoop install python312 }

Step "Prereq: CUDA Toolkit 12.8 (NOT 13.x)"
if (Test-Path "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.8") {
  Write-Host "CUDA 12.8 ok"
} elseif (Have winget) {
  Write-Host "Installing CUDA Toolkit 12.8 (large download, several minutes)..." -ForegroundColor Yellow
  winget install Nvidia.CUDA --version 12.8 --accept-package-agreements --accept-source-agreements --disable-interactivity
} else {
  Write-Warning "winget not found — install CUDA Toolkit 12.8 manually, then re-run."
}

Step "Bootstrap: submodules -> build engine+proxy -> venvs+tools -> models"
$ba = @(); if ($SkipModels) { $ba += '-SkipModels' }
& "$PSScriptRoot\bootstrap.ps1" @ba

Step "Wire clients (Continue + aider)"
& "$PSScriptRoot\setup-clients.ps1"

Step "Install 'llm' CLI command"
& "$PSScriptRoot\install-cli.ps1"

Step "All set"
Write-Host "Open a new terminal, then:  llm up   (or  llm help  for all commands)" -ForegroundColor Green
if ($Launch) { & "$PSScriptRoot\up.ps1" }
