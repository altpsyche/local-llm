#requires -Version 7
# Download GGUF models listed in models/models.manifest into models/ (gitignored).
# Uses curl.exe (built into Windows) with resume (-C -). Re-run any time — existing files skipped.
# Public repos need no token; for gated repos set $env:HF_TOKEN and it'll be sent as a bearer header.
$ErrorActionPreference = "Stop"
$repo     = Split-Path $PSScriptRoot -Parent
$manifest = Join-Path $repo "models\models.manifest"
$outDir   = Join-Path $repo "models"
if (-not (Test-Path $manifest)) { throw "manifest not found: $manifest" }
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw "curl.exe not found (needs Windows 10+)." }

$hdr = @()
if ($env:HF_TOKEN) { $hdr = @("-H", "Authorization: Bearer $env:HF_TOKEN") }

$fail = 0
Get-Content $manifest | ForEach-Object {
  $line = $_.Trim()
  if ($line -eq "" -or $line.StartsWith("#")) { return }
  $parts = ($line -split "\|") | ForEach-Object { $_.Trim() }
  if ($parts.Count -lt 3) { Write-Warning "skip malformed: $line"; return }
  $local, $hfRepo, $hfPath = $parts[0], $parts[1], $parts[2]
  $dest = Join-Path $outDir $local
  if (Test-Path $dest) { Write-Host "exists  $local" -ForegroundColor DarkGray; return }

  $url = "https://huggingface.co/$hfRepo/resolve/main/$hfPath"
  Write-Host "fetch   $local  <-  $hfRepo / $hfPath" -ForegroundColor Cyan
  curl.exe -L -C - --fail-with-body @hdr -o "$dest.part" $url
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "FAILED $url  (verify repo/filename on huggingface.co)"; $fail++
    return
  }
  Move-Item "$dest.part" $dest -Force
  Write-Host "done    $local" -ForegroundColor Green
}
Write-Host "`nModels in $outDir :" -ForegroundColor Green
Get-ChildItem $outDir -Filter *.gguf | Select-Object Name, @{n='GB';e={[math]::Round($_.Length/1GB,1)}} | Format-Table -AutoSize
if ($fail) { Write-Warning "$fail model(s) failed — fix manifest lines and re-run." }
