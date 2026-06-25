#requires -Version 7
# Machine-readiness check: GPU, VRAM, CUDA compatibility, active profile, and model files.
# Called automatically at the start of setup.bat. Also available standalone: llm diagnose
param()
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\_models.ps1"

$issues = 0
function Row([string]$label, [string]$value, [string]$fg = 'White') {
  Write-Host ("  {0,-10}  {1}" -f $label, $value) -ForegroundColor $fg
}

Write-Host "`nSystem check" -ForegroundColor Cyan
Write-Host ('-' * 52)

# GPU + VRAM
$gpu  = Get-GpuArch
$vram = Get-GpuVramGB
if ($gpu) {
  Row "GPU"  "$($gpu.Gen)  (sm_$($gpu.CudaArch))"
  Row "VRAM" "$vram GB"
} else {
  Row "GPU"  "not detected  (nvidia-smi not found or no NVIDIA GPU)" 'DarkGray'
  Row "VRAM" "unknown" 'DarkGray'
}

# Profile
$cfg    = Get-ModelsConfig
$active = $cfg.activeProfile
$sug    = Get-SuggestedProfile -VramGB $vram
if ($sug -and $sug -eq $active) {
  Row "Profile" "$active  (good fit for $vram GB VRAM)" 'Green'
} elseif ($sug -and $sug -ne $active) {
  Row "Profile" "$active  (will auto-switch to '$sug' at setup)" 'Yellow'
} else {
  Row "Profile" $active 'DarkGray'
}

# CUDA
$cudaBase  = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA'
$installed = @()
if (Test-Path $cudaBase) {
  $installed = @(Get-ChildItem $cudaBase -Directory | ForEach-Object {
    if ($_.Name -match '^v(\d+)\.(\d+)$') {
      [pscustomobject]@{ Name = $_.Name; Major = [int]$Matches[1]; Minor = [int]$Matches[2] }
    }
  } | Where-Object { $_ })
}

if ($gpu) {
  $best = Get-BestCudaRoot -CudaArch $gpu.CudaArch
  if ($best) {
    Row "CUDA" "$(Split-Path $best -Leaf)  ok" 'Green'
  } else {
    $need  = if ($gpu.CudaArch -ge 120) { '12.8 (required for Blackwell)' } else { '12.x' }
    $found = if ($installed.Count -gt 0) { "found: $(($installed | ForEach-Object { $_.Name }) -join ', ')" } else { 'none installed' }
    Row "CUDA" "needs $need  ($found)  — setup will install" 'Yellow'
    $issues++
  }
} else {
  $label = if ($installed.Count -gt 0) { ($installed | ForEach-Object { $_.Name } | Sort-Object | Select-Object -Last 1) + '  (no GPU detected)' } else { 'not installed  (no GPU detected — skipping)' }
  Row "CUDA" $label 'DarkGray'
}

# Models
$pname   = Resolve-ProfileName -Config $cfg
$prof    = $cfg.profiles[$pname]
$mdir    = Join-Path $repo 'models'
$present = 0; $mtotal = 0; $bad = @()

foreach ($role in @('planner','coder','chat','fim','embed')) {
  $m = $prof[$role]; if (-not $m) { continue }
  $mtotal++
  $f = Join-Path $mdir $m['gguf']
  if (-not (Test-Path $f)) { continue }
  $present++
  if (Test-Path "$f.part") {
    $bad += "$($m['gguf'])  (partial download — delete and re-run: llm fetch)"
  } else {
    $expGB = [float]$m['sizeGB']; $actGB = (Get-Item $f).Length / 1GB
    if ($actGB -lt $expGB * 0.90 -or $actGB -gt $expGB * 1.10) {
      $bad += "$($m['gguf'])  (size $([math]::Round($actGB,1)) GB, expected ~$expGB GB — re-download: llm fetch)"
    }
  }
}

if ($bad.Count -gt 0) {
  Row "Models" "$present / $mtotal present  — $($bad.Count) corrupt" 'Red'
  foreach ($b in $bad) { Write-Host "             $b" -ForegroundColor Red }
  $issues++
} elseif ($present -gt 0) {
  $fc = if ($present -lt $mtotal) { 'Yellow' } else { 'Green' }
  Row "Models" "$present / $mtotal present  (profile: $pname)" $fc
} else {
  Row "Models" "none downloaded yet  (profile: $pname)  — setup will fetch" 'DarkGray'
}

Write-Host ('-' * 52)
if ($issues -gt 0) {
  Write-Host "  $issues issue(s) noted above. Setup will attempt to resolve them." -ForegroundColor Yellow
} else {
  Write-Host "  All checks passed." -ForegroundColor Green
}
Write-Host ''
