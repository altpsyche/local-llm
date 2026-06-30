#requires -Version 7
# Download the GGUF models for the active profile (config/models.psd1) into models/.
# Single source of truth: config/models.psd1 (see also scripts/gen-llama-swap.ps1).
# Uses curl.exe (built into Windows) with resume (-C -). Re-run any time — existing files skipped.
# Public repos need no token; for gated repos set $env:HF_TOKEN and it'll be sent as a bearer header.
#   .\scripts\fetch-models.ps1                 # active profile
#   .\scripts\fetch-models.ps1 -Profile 12gb   # a specific profile (does not persist)
#   .\scripts\fetch-models.ps1 -ListOnly       # dry-run: list files + sizes, download nothing
param([string]$Profile, [switch]$ListOnly)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_models.ps1"

function Update-Manifest {
    param([string]$ModelsDir, [string]$Gguf, [string]$Url, [double]$SizeGB)
    $manifestPath = Join-Path $ModelsDir 'manifest.json'
    $manifest = if (Test-Path $manifestPath) {
        Get-Content $manifestPath -Raw | ConvertFrom-Json -AsHashtable
    } else { @{} }
    Write-Host "  Computing SHA256 for $Gguf (large files ~15s)..."
    $hash = (Get-FileHash (Join-Path $ModelsDir $Gguf) -Algorithm SHA256).Hash.ToLower()
    $manifest[$Gguf] = @{ sha256=$hash; sizeGB=$SizeGB; url=$Url; verifiedAt=(Get-Date -Format 'o') }
    $manifest | ConvertTo-Json -Depth 3 | Set-Content $manifestPath -Encoding utf8
    Write-Host "  SHA256: $($hash.Substring(0,16))... -> models/manifest.json" -ForegroundColor DarkGray
}

$repo   = Split-Path $PSScriptRoot -Parent
$outDir = Join-Path $repo "models"

$resolved = Get-Models -Profile $Profile
$name     = $resolved.profile
$models   = $resolved.models
$totalGB  = ($models | Measure-Object -Property sizeGB -Sum).Sum

Write-Host "Profile '$name': $($models.Count) models, ~$([math]::Round($totalGB,1)) GB total" -ForegroundColor Cyan

if ($ListOnly) {
  $rows = [System.Collections.Generic.List[pscustomobject]]::new()
  foreach ($m in $models) {
    $dest    = Join-Path $outDir $m.gguf
    $present = if (Test-Path $dest) { "present" } else { "MISSING" }
    $rows.Add([pscustomobject]@{ model = $m.role; file = $m.gguf; GB = $m.sizeGB; status = $present; from = "$($m.repo)/$($m.path)" })
    if ($m.mmproj) {
      $mDest    = Join-Path $outDir $m.mmproj
      $mPresent = if (Test-Path $mDest) { "present" } else { "MISSING" }
      $rows.Add([pscustomobject]@{ model = "$($m.role)/mmproj"; file = $m.mmproj; GB = '~0.6'; status = $mPresent; from = "$($m.repo)/$($m.mmproj)" })
    }
  }
  $rows | Format-Table -AutoSize
  Write-Host "(dry run — nothing downloaded)" -ForegroundColor DarkGray
  return
}

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw "curl.exe not found (needs Windows 10+)." }
$hdr = @()
if ($env:HF_TOKEN) { $hdr = @("-H", "Authorization: Bearer $env:HF_TOKEN") }

# disk-space pre-check
$missing  = @($models | Where-Object { -not (Test-Path (Join-Path $outDir $_.gguf)) })
$neededGB = ($missing | Measure-Object -Property sizeGB -Sum).Sum
if ($neededGB -gt 0) {
  $drive = Split-Path $outDir -Qualifier   # string-only parse, works before dir exists
  $drv   = Get-PSDrive ($drive -replace ':','') -ErrorAction SilentlyContinue
  if ($drv) {
    $freeGB = $drv.Free / 1GB
    if ($freeGB -lt $neededGB * 1.2) {
      Write-Warning ("Low disk space: {0:N1} GB free, ~{1:N1} GB needed (+20% buffer = {2:N1} GB)" -f `
        $freeGB, $neededGB, ($neededGB * 1.2))
    }
  }
}
$staleParts = @(Get-ChildItem $outDir -Filter '*.gguf.part' -ErrorAction SilentlyContinue)
if ($staleParts.Count -gt 0) {
  Write-Warning "$($staleParts.Count) stale .part file(s) in $outDir — curl will resume them."
}

$fail = 0
foreach ($m in $models) {
  $dest = Join-Path $outDir $m.gguf
  if (Test-Path $dest) { Write-Host "exists  $($m.gguf)" -ForegroundColor DarkGray }
  else {
    $url = "https://huggingface.co/$($m.repo)/resolve/main/$($m.path)"
    Write-Host "fetch   $($m.gguf)  <-  $($m.repo) / $($m.path)" -ForegroundColor Cyan
    $dlSw = [Diagnostics.Stopwatch]::StartNew()
    curl.exe -L -C - --fail-with-body --progress-bar @hdr -o "$dest.part" $url
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "FAILED $url  (verify repo/filename on huggingface.co)"; $fail++; continue
    }
    Move-Item "$dest.part" $dest -Force
    Update-Manifest -ModelsDir $outDir -Gguf $m.gguf -Url $url -SizeGB $m.sizeGB
    Write-Host "done    $($m.gguf)  ($($m.sizeGB) GB in $([int]$dlSw.Elapsed.TotalMinutes)m$($dlSw.Elapsed.Seconds)s)" -ForegroundColor Green
  }

  # Download mmproj (multimodal projector) when present — same repo, different file.
  if ($m.mmproj) {
    $mmprojDest = Join-Path $outDir $m.mmproj
    if (Test-Path $mmprojDest) { Write-Host "exists  $($m.mmproj)" -ForegroundColor DarkGray }
    else {
      $mmprojUrl = "https://huggingface.co/$($m.repo)/resolve/main/$($m.mmproj)"
      Write-Host "fetch   $($m.mmproj)  <-  $($m.repo) / $($m.mmproj)" -ForegroundColor Cyan
      $dlSw2 = [Diagnostics.Stopwatch]::StartNew()
      curl.exe -L -C - --fail-with-body --progress-bar @hdr -o "$mmprojDest.part" $mmprojUrl
      if ($LASTEXITCODE -ne 0) {
        Write-Warning "FAILED $mmprojUrl  (verify mmproj filename on huggingface.co)"; $fail++
      } else {
        Move-Item "$mmprojDest.part" $mmprojDest -Force
        Write-Host "done    $($m.mmproj) in $([int]$dlSw2.Elapsed.TotalMinutes)m$($dlSw2.Elapsed.Seconds)s" -ForegroundColor Green
      }
    }
  }
}

Write-Host "`nModels in $outDir :" -ForegroundColor Green
Get-ChildItem $outDir -Filter *.gguf | Select-Object Name, @{n='GB';e={[math]::Round($_.Length/1GB,1)}} | Format-Table -AutoSize
if ($fail) { Write-Warning "$fail model(s) failed — fix config\models.psd1 and re-run." }
