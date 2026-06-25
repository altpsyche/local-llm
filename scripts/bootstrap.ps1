#requires -Version 7
# One-shot setup: submodules -> build engine + proxy -> Python venvs -> fetch models.
# Re-runnable. Heavy steps are skippable via flags.
#   .\scripts\bootstrap.ps1                 # full
#   .\scripts\bootstrap.ps1 -SkipModels     # everything except the multi-GB downloads
param([switch]$SkipModels, [switch]$SkipBuild, [string]$Profile)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\_models.ps1"

function Have($n) { [bool](Get-Command $n -ErrorAction SilentlyContinue) }
function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

# Profile selection. Explicit -Profile wins; otherwise suggest one from detected VRAM (never forces).
if ($Profile) {
  Step "Select profile '$Profile'"; Set-ActiveProfile $Profile
} else {
  $vram = Get-GpuVramGB
  $sug  = Get-SuggestedProfile -VramGB $vram
  $active = (Get-ModelsConfig).activeProfile
  if ($sug -and $sug -ne $active) {
    Step "VRAM check — auto-selecting profile"
    Write-Host "Detected ~$vram GB VRAM -> switching profile '$active' -> '$sug'" -ForegroundColor Cyan
    Set-ActiveProfile $sug
  } elseif ($sug) {
    Write-Host "VRAM ~$vram GB -> profile '$active' (good fit)." -ForegroundColor DarkGray
  }
}

# GPU architecture + compatible CUDA root (used for prereq report and passed to build-llama).
$gpuArch  = Get-GpuArch
$cudaRoot = if ($gpuArch) { Get-BestCudaRoot -CudaArch $gpuArch.CudaArch } else { Get-BestCudaRoot -CudaArch 120 }

# --- prereq report ---
Step "Prereqs"
if (-not (Have git))   { throw "git missing" }
if (-not (Have cmake)) { throw "cmake missing" }
"git    : ok"
"cmake  : ok"
if ($gpuArch) { "GPU    : $($gpuArch.Gen) (sm_$($gpuArch.CudaArch))" }
"CUDA   : $(if ($cudaRoot) { "ok — $cudaRoot" } else { 'MISSING — install CUDA 12.x before building' })"
"go     : $(if (Have go) { 'ok' } else { 'missing — will need llama-swap release binary instead' })"

# locate Python 3.12 (scoop)
$py = $null
try { $p = (scoop prefix python312) 2>$null; if ($p) { $py = Join-Path $p "python.exe" } } catch {}
if (-not $py -or -not (Test-Path $py)) { if (Have python3.12) { $py = "python3.12" } }
"python : $(if ($py) { $py } else { 'MISSING — scoop install python312' })"

# --- submodules ---
Step "Submodules"
git -C $repo submodule update --init --recursive
if ($LASTEXITCODE -ne 0) { throw "submodule init failed" }

# --- build engine + proxy ---
if (-not $SkipBuild) {
  if ($cudaRoot) {
    $label = if ($gpuArch) { "$($gpuArch.Gen) sm_$($gpuArch.CudaArch)" } else { 'sm_120 (default)' }
    Step "Build llama.cpp ($label)"
    $buildArgs = @('-CudaRoot', $cudaRoot)
    if ($gpuArch) { $buildArgs += @('-Arch', $gpuArch.CudaArch) }
    & "$PSScriptRoot\build-llama.ps1" @buildArgs
  } else {
    Write-Warning "Skipping llama.cpp build — no compatible CUDA toolkit found. Install CUDA 12.x, or drop a prebuilt llama-server.exe into bin\."
  }

  Step "Build llama-swap"
  if (Have go) { & "$PSScriptRoot\build-llama-swap.ps1" }
  else { Write-Warning "Skipping llama-swap build — Go missing. Download the release binary into bin\llama-swap.exe." }
} else { Write-Host "Skipping builds (-SkipBuild)" -ForegroundColor DarkGray }

# --- Python tools: ISOLATED venvs (open-webui & aider have conflicting dep pins) ---
Step "Python venvs (3.12) + tools"
if ($py) {
  foreach ($t in @(@{n='venv-webui'; base='webui-requirements'}, @{n='venv-aider'; base='aider-requirements'})) {
    $venv = Join-Path $repo "tools\$($t.n)"
    if (-not (Test-Path $venv)) { & $py -m venv $venv }
    $venvPy = Join-Path $venv "Scripts\python.exe"
    if (-not (Test-Path $venvPy)) { throw "venv creation failed for $($t.n) — $venvPy not found" }
    & $venvPy -m pip install --upgrade pip
    # prefer the pinned .lock (reproducible); fall back to the loose .txt on a first-ever run
    $lock = Join-Path $repo "tools\$($t.base).lock"
    $req  = if (Test-Path $lock) { $lock } else { Join-Path $repo "tools\$($t.base).txt" }
    & $venvPy -m pip install -r $req
    if ($LASTEXITCODE -ne 0) { throw "pip install failed for $($t.n) — re-run scripts\bootstrap.ps1 to retry" }
  }
} else { Write-Warning "Skipping venvs — Python 3.12 not found." }

# --- runtime config (generated from config/models.psd1; runs even with -SkipModels) ---
Step "Generate llama-swap config"
& "$PSScriptRoot\gen-llama-swap.ps1"

# --- models ---
if (-not $SkipModels) { Step "Fetch models (multi-GB)"; & "$PSScriptRoot\fetch-models.ps1" }
else { Write-Host "Skipping model downloads (-SkipModels). Run scripts\fetch-models.ps1 later." -ForegroundColor DarkGray }

Step "Done"
Write-Host "Next: .\scripts\start.ps1   then point tools at http://localhost:8080/v1  (see docs\USAGE.md)" -ForegroundColor Green
