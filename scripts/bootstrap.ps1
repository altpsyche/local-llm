#requires -Version 7
# One-shot setup: submodules -> build engine + proxy -> Python venv -> fetch models.
# Re-runnable. Heavy steps are skippable via flags.
#   .\scripts\bootstrap.ps1                 # full
#   .\scripts\bootstrap.ps1 -SkipModels     # everything except the multi-GB downloads
param([switch]$SkipModels, [switch]$SkipBuild)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent

function Have($n) { [bool](Get-Command $n -ErrorAction SilentlyContinue) }
function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

# --- prereq report ---
Step "Prereqs"
if (-not (Have git))   { throw "git missing" }
if (-not (Have cmake)) { throw "cmake missing" }
$cuda = Test-Path "C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v12.8"
"git    : ok"
"cmake  : ok"
"CUDA128: $(if($cuda){'ok'}else{'MISSING — install CUDA Toolkit 12.8 (not 13.x) before building'})"
"go     : $(if(Have go){'ok'}else{'missing — will need llama-swap release binary instead'})"

# locate Python 3.12 (scoop)
$py = $null
try { $p = (scoop prefix python312) 2>$null; if ($p) { $py = Join-Path $p "python.exe" } } catch {}
if (-not $py -or -not (Test-Path $py)) { if (Have python3.12) { $py = "python3.12" } }
"python : $(if($py){$py}else{'MISSING — scoop install python312'})"

# --- submodules ---
Step "Submodules"
git -C $repo submodule update --init --recursive
if ($LASTEXITCODE -ne 0) { throw "submodule init failed" }

# --- build engine + proxy ---
if (-not $SkipBuild) {
  if ($cuda) { Step "Build llama.cpp (CUDA 12.8)"; & "$PSScriptRoot\build-llama.ps1" }
  else { Write-Warning "Skipping llama.cpp build — CUDA 12.8 not installed." }

  Step "Build llama-swap"
  if (Have go) { & "$PSScriptRoot\build-llama-swap.ps1" }
  else { Write-Warning "Skipping llama-swap build — Go missing. Download release binary into bin\llama-swap.exe." }
} else { Write-Host "Skipping builds (-SkipBuild)" -ForegroundColor DarkGray }

# --- Python venv + tools ---
Step "Python venv (3.12) + tools"
if ($py) {
  $venv = Join-Path $repo "tools\venv312"
  if (-not (Test-Path $venv)) { & $py -m venv $venv }
  & "$venv\Scripts\python.exe" -m pip install --upgrade pip
  & "$venv\Scripts\python.exe" -m pip install -r (Join-Path $repo "tools\requirements.txt")
} else { Write-Warning "Skipping venv — Python 3.12 not found." }

# --- models ---
if (-not $SkipModels) { Step "Fetch models (multi-GB)"; & "$PSScriptRoot\fetch-models.ps1" }
else { Write-Host "Skipping model downloads (-SkipModels). Run scripts\fetch-models.ps1 later." -ForegroundColor DarkGray }

Step "Done"
Write-Host "Next: .\scripts\start.ps1   then point tools at http://localhost:8080/v1  (see docs\USAGE.md)" -ForegroundColor Green
