#!/usr/bin/env pwsh
# N8 — install Bob's versioned git hooks into .git/hooks (which git does not track).
# Run once per clone:  pwsh -File scripts\install-hooks.ps1
$repo = Split-Path $PSScriptRoot -Parent
$src = Join-Path $repo 'scripts\hooks\pre-commit'
$hooksDir = Join-Path $repo '.git\hooks'
if (-not (Test-Path $hooksDir)) {
  Write-Host "No .git\hooks directory found — is this a git checkout?" -ForegroundColor Red
  exit 1
}
Copy-Item $src (Join-Path $hooksDir 'pre-commit') -Force
Write-Host "Installed pre-commit hook -> $hooksDir\pre-commit" -ForegroundColor Green
Write-Host "It runs scripts\check.ps1 (py_compile + PowerShell parse + unittest) and blocks on failure." -ForegroundColor DarkGray
