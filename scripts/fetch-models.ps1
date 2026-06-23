#requires -Version 7
# Download GGUF models listed in models/models.manifest into models/ (gitignored).
# Uses the venv's huggingface-cli; resumable. Re-run any time — existing files are skipped.
$ErrorActionPreference = "Stop"
$repo     = Split-Path $PSScriptRoot -Parent
$manifest = Join-Path $repo "models\models.manifest"
$outDir   = Join-Path $repo "models"
$hf       = Join-Path $repo "tools\venv312\Scripts\huggingface-cli.exe"

if (-not (Test-Path $manifest)) { throw "manifest not found: $manifest" }
if (-not (Test-Path $hf)) {
  throw "huggingface-cli not found at $hf. Run bootstrap.ps1 first (creates venv + installs huggingface-hub)."
}

$tmp = Join-Path $outDir ".hf-cache"
Get-Content $manifest | ForEach-Object {
  $line = $_.Trim()
  if ($line -eq "" -or $line.StartsWith("#")) { return }
  $parts = $line.Split("|") | ForEach-Object { $_.Trim() }
  if ($parts.Count -lt 3) { Write-Warning "skip malformed line: $line"; return }
  $local, $hfRepo, $hfPath = $parts[0], $parts[1], $parts[2]
  $dest = Join-Path $outDir $local

  if (Test-Path $dest) { Write-Host "exists  $local" -ForegroundColor DarkGray; return }
  Write-Host "fetch   $local  <-  $hfRepo / $hfPath" -ForegroundColor Cyan
  & $hf download $hfRepo $hfPath --local-dir $tmp
  if ($LASTEXITCODE -ne 0) { Write-Warning "FAILED $hfRepo/$hfPath — verify repo/filename on huggingface.co"; return }
  Move-Item (Join-Path $tmp $hfPath) $dest -Force
}
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
Write-Host "Done. Models in $outDir :" -ForegroundColor Green
Get-ChildItem $outDir -Filter *.gguf | Select-Object Name, @{n='GB';e={[math]::Round($_.Length/1GB,1)}} | Format-Table -AutoSize
