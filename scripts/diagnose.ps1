#requires -Version 7
# Machine-readiness check: GPU, VRAM, CUDA compatibility, active profile, and model files.
# Called automatically at the start of setup.bat. Also available standalone: bob diagnose
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
  $faNote = if ($gpu.CudaArch -lt 75) { '  (WARNING: flash-attn requires sm_75+; disable flashAttn in user.psd1)' } else { '' }
  Row "GPU"  "$($gpu.Gen)  (sm_$($gpu.CudaArch))$faNote" $(if ($gpu.CudaArch -lt 75) { 'Yellow' } else { 'White' })
  Row "VRAM" "$vram GB"
} else {
  Row "GPU"  "not detected  (nvidia-smi not found or no NVIDIA GPU)" 'DarkGray'
  Row "VRAM" "unknown" 'DarkGray'
}

# System RAM
$ram = Get-SystemRamGB
if ($ram) {
  $ramColor = if ($ram.FreeGB -ge 32) { 'Green' } elseif ($ram.FreeGB -ge 16) { 'White' } else { 'Yellow' }
  Row "RAM" "$($ram.TotalGB) GB total  ($($ram.FreeGB) GB free)" $ramColor
} else {
  Row "RAM" "unknown" 'DarkGray'
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

$port = $cfg.defaults.port ?? 8080
$epUp = $false
try { $c = [System.Net.Sockets.TcpClient]::new(); $c.Connect('127.0.0.1', $port); $epUp = $true; $c.Close() } catch {}
Row "Endpoint" "http://localhost:$port/v1  ($(if ($epUp) { 'up' } else { 'not running' }))" $(if ($epUp) { 'Green' } else { 'DarkGray' })

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

# mlock privilege
$mlockGranted = $false
try {
    $mlockResult = & "$PSScriptRoot\grant-mlock.ps1" -Check 2>&1
    $mlockGranted = ($LASTEXITCODE -eq 0)
} catch {}
$d = $cfg.defaults
$mlockEnabled = ($d.mlockBig -eq $true)
if ($mlockEnabled -and -not $mlockGranted) {
    Row "mlock" "mlockBig=true but SeLockMemoryPrivilege NOT granted — run: bob mlock" 'Yellow'
    $issues++
} elseif ($mlockEnabled -and $mlockGranted) {
    Row "mlock" "SeLockMemoryPrivilege granted  (--mlock active)" 'Green'
} else {
    $mlockRamHint = if ($ram -and $ram.FreeGB -ge 32) { "  — $($ram.FreeGB) GB free RAM; eligible" } else { '' }
    Row "mlock" "not enabled$mlockRamHint  (set mlockBig=true in user.psd1 + run: bob mlock)" 'DarkGray'
}

# NUMA topology vs config
$numaNodes = Get-NumaNodeCount
$numaConfig = $cfg.defaults.numa
if ($numaConfig -and $numaConfig -ne '') {
    if ($numaNodes -le 1) {
        Row "NUMA" "config: '--numa $numaConfig' but Windows reports $numaNodes node — flag is a no-op; set numa='' in user.psd1" 'Yellow'
        $issues++
    } else {
        Row "NUMA" "$numaNodes nodes  — '--numa $numaConfig' active" 'Green'
    }
} else {
    $numaNote = if ($numaNodes -gt 1) { "$numaNodes nodes detected — consider numa='isolate' in user.psd1 for CPU-offload gains" } else { "$numaNodes NUMA node  (disabled, correct for this topology)" }
    Row "NUMA" $numaNote 'DarkGray'
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
    $bad += "$($m['gguf'])  (partial download — delete and re-run: bob fetch)"
  } else {
    $expGB = [float]$m['sizeGB']; $actGB = (Get-Item $f).Length / 1GB
    if ($actGB -lt $expGB * (1 - $script:SizeTolPct) -or $actGB -gt $expGB * (1 + $script:SizeTolPct)) {
      $bad += "$($m['gguf'])  (size $([math]::Round($actGB,1)) GB, expected ~$expGB GB — re-download: bob fetch)"
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

# Manifest coverage (D8) — presence only, no re-hashing
$manifestPath = Join-Path $mdir 'manifest.json'
$manifest = if (Test-Path $manifestPath) {
  Get-Content $manifestPath -Raw | ConvertFrom-Json -AsHashtable
} else { @{} }
$mCovered = 0; $mTotal = 0
foreach ($role in @('planner','coder','chat','fim','embed')) {
  $m = $prof[$role]; if (-not $m) { continue }
  if (-not (Test-Path (Join-Path $mdir $m['gguf']))) { continue }
  $mTotal++
  if ($manifest[$m['gguf']]) { $mCovered++ }
}
if ($mTotal -gt 0) {
  $mColor = if ($mCovered -eq $mTotal) { 'Green' } elseif ($mCovered -gt 0) { 'Yellow' } else { 'DarkGray' }
  Row "Manifest" "$mCovered / $mTotal SHA256 recorded  (bob fetch to populate)" $mColor
}

Write-Host ('-' * 52)
if ($issues -gt 0) {
  Write-Host "  $issues issue(s) noted above. Setup will attempt to resolve them." -ForegroundColor Yellow
} else {
  Write-Host "  All checks passed." -ForegroundColor Green
}
Write-Host ''
