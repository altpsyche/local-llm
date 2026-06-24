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

$repo   = Split-Path $PSScriptRoot -Parent
$outDir = Join-Path $repo "models"

$resolved = Get-Models -Profile $Profile
$name     = $resolved.profile
$models   = $resolved.models
$totalGB  = ($models | Measure-Object -Property sizeGB -Sum).Sum

Write-Host "Profile '$name': $($models.Count) models, ~$([math]::Round($totalGB,1)) GB total" -ForegroundColor Cyan

if ($ListOnly) {
  $models | ForEach-Object {
    $dest    = Join-Path $outDir $_.gguf
    $present = if (Test-Path $dest) { "present" } else { "MISSING" }
    [pscustomobject]@{ model = $_.role; file = $_.gguf; GB = $_.sizeGB; status = $present; from = "$($_.repo)/$($_.path)" }
  } | Format-Table -AutoSize
  Write-Host "(dry run — nothing downloaded)" -ForegroundColor DarkGray
  return
}

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw "curl.exe not found (needs Windows 10+)." }
$hdr = @()
if ($env:HF_TOKEN) { $hdr = @("-H", "Authorization: Bearer $env:HF_TOKEN") }

$fail = 0
foreach ($m in $models) {
  $dest = Join-Path $outDir $m.gguf
  if (Test-Path $dest) { Write-Host "exists  $($m.gguf)" -ForegroundColor DarkGray; continue }

  $url = "https://huggingface.co/$($m.repo)/resolve/main/$($m.path)"
  Write-Host "fetch   $($m.gguf)  <-  $($m.repo) / $($m.path)" -ForegroundColor Cyan
  curl.exe -L -C - --fail-with-body @hdr -o "$dest.part" $url
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "FAILED $url  (verify repo/filename on huggingface.co)"; $fail++
    continue
  }
  Move-Item "$dest.part" $dest -Force
  Write-Host "done    $($m.gguf)" -ForegroundColor Green
}

Write-Host "`nModels in $outDir :" -ForegroundColor Green
Get-ChildItem $outDir -Filter *.gguf | Select-Object Name, @{n='GB';e={[math]::Round($_.Length/1GB,1)}} | Format-Table -AutoSize
if ($fail) { Write-Warning "$fail model(s) failed — fix config\models.psd1 and re-run." }
