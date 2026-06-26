#requires -Version 7
# Create the lm-evaluation-harness venv (tools/venv-eval/).
# Run once. After this, 'llm eval <role> [task]' benchmarks any model.
$ErrorActionPreference = "Stop"
$pyVer = & python --version 2>&1
if ($pyVer -notmatch '3\.12') {
    throw "Python 3.12 required (found: $pyVer). Install: scoop install python312"
}
$repo = Split-Path $PSScriptRoot -Parent
$venv = Join-Path $repo 'tools\venv-eval'

if (Test-Path $venv) {
    Write-Host "venv-eval already exists — skipping. Delete it to reinstall." -ForegroundColor DarkGray
    return
}

Write-Host "Creating eval venv..." -ForegroundColor Cyan
python -m venv $venv
if ($LASTEXITCODE -ne 0) { throw "python -m venv failed. Is Python 3.12 installed?" }

Write-Host "Installing lm-eval (this may take a few minutes)..." -ForegroundColor Cyan
& "$venv\Scripts\pip.exe" install -r "$repo\tools\eval-requirements.txt" --quiet
if ($LASTEXITCODE -ne 0) { throw "pip install failed." }

Write-Host "lm-eval installed at tools/venv-eval/" -ForegroundColor Green
Write-Host "Quick smoke test:  llm eval coder gsm8k --limit 100  (~8 min)" -ForegroundColor DarkGray
Write-Host "Full benchmark:    llm eval coder gsm8k               (~90 min)" -ForegroundColor DarkGray
