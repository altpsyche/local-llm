#requires -Version 7
# Install the 'llm' command on PATH (a .cmd shim in scoop\shims pointing at scripts/llm.ps1).
# Works from any shell (cmd or PowerShell). Idempotent.
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$llm  = Join-Path $repo "scripts\llm.ps1"
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source

# locate a PATH dir to drop the shim into (prefer scoop\shims)
$shimDir = $null
$sc = Get-Command scoop -ErrorAction SilentlyContinue
if ($sc -and $sc.Source) { $shimDir = Split-Path $sc.Source }
if (-not $shimDir -or -not (Test-Path $shimDir)) { $shimDir = Join-Path $HOME "scoop\shims" }
if (-not (Test-Path $shimDir)) { throw "No scoop\shims dir found at $shimDir. Add scripts\ to PATH manually instead." }

$cmdPath = Join-Path $shimDir "llm.cmd"
@"
@echo off
"$pwsh" -NoProfile -ExecutionPolicy Bypass -File "$llm" %*
"@ | Set-Content -Path $cmdPath -Encoding ascii

Write-Host "'llm' installed -> $cmdPath" -ForegroundColor Green
Write-Host "Open a NEW terminal, then try:  llm help" -ForegroundColor Cyan
