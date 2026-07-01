#!/usr/bin/env pwsh
# N8 — pre-commit / CI gate. Runs, in order:
#   1. py_compile over scripts/, plugins/, tests/ (excluding external/)
#   2. PowerShell AST parse over scripts/*.ps1 and config/*.psd1
#   3. the stdlib-unittest suite in tests/   (skip with -NoTests)
# Exits non-zero on the first category that fails, so a git pre-commit hook (or CI) blocks.
param([switch]$NoTests)

$repo = Split-Path $PSScriptRoot -Parent
$venvPy = Join-Path $repo 'tools\venv-litellm\Scripts\python.exe'
if (-not (Test-Path $venvPy)) {
  Write-Host "[check] venv-litellm not found at $venvPy — run scripts\bootstrap-litellm.ps1" -ForegroundColor Red
  exit 1
}
$failed = $false

# 1. py_compile ------------------------------------------------------------
Write-Host '[check] py_compile...' -ForegroundColor Cyan
$pyFiles = Get-ChildItem -Path (Join-Path $repo 'scripts'), (Join-Path $repo 'plugins'), (Join-Path $repo 'tests') `
  -Recurse -Filter *.py -File -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch '[\\/]external[\\/]' } |
  Select-Object -ExpandProperty FullName
& $venvPy -m py_compile @pyFiles
if ($LASTEXITCODE -ne 0) { Write-Host '[check] py_compile FAILED' -ForegroundColor Red; $failed = $true }

# 2. PowerShell AST parse --------------------------------------------------
# Exclude bob-toast.ps1: it uses WinRT type accelerators
# ([Windows.UI.Notifications...,ContentType=WindowsRuntime]) which the static AST parser reports
# as errors even though PowerShell runs them fine — a known ParseFile false positive.
Write-Host '[check] PowerShell AST parse...' -ForegroundColor Cyan
$psFiles = Get-ChildItem -Path (Join-Path $repo 'scripts'), (Join-Path $repo 'config') `
  -Recurse -Include *.ps1, *.psd1 -File -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch '[\\/]external[\\/]' -and $_.Name -ne 'bob-toast.ps1' }
foreach ($f in $psFiles) {
  $errs = $null
  [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs) | Out-Null
  if ($errs) {
    Write-Host "[check] PARSE ERROR: $($f.FullName)" -ForegroundColor Red
    $errs | ForEach-Object { Write-Host "     $($_.Message)" -ForegroundColor DarkYellow }
    $failed = $true
  }
}

# 3. unittest suite --------------------------------------------------------
if (-not $NoTests) {
  Write-Host '[check] unittest suite...' -ForegroundColor Cyan
  $env:PYTHONIOENCODING = 'utf-8'
  & $venvPy -m unittest discover -s (Join-Path $repo 'tests') -p 'test_*.py'
  if ($LASTEXITCODE -ne 0) { Write-Host '[check] tests FAILED' -ForegroundColor Red; $failed = $true }
  $env:PYTHONIOENCODING = $null
}

if ($failed) { Write-Host '[check] FAILED' -ForegroundColor Red; exit 1 }
Write-Host '[check] all green' -ForegroundColor Green
exit 0
