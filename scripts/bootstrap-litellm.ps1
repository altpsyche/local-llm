#requires -Version 7
# Create the LiteLLM proxy venv (tools/venv-litellm/).
# Run once. After this, 'bob litellm' starts the proxy on port 8081.
$ErrorActionPreference = "Stop"
$pyVer = & python --version 2>&1
if ($pyVer -notmatch '3\.12') {
    throw "Python 3.12 required (found: $pyVer). Install: scoop install python312"
}
$repo = Split-Path $PSScriptRoot -Parent
$venv = Join-Path $repo 'tools\venv-litellm'

if (Test-Path $venv) {
    Write-Host "venv-litellm already exists — skipping. Delete it to reinstall." -ForegroundColor DarkGray
    return
}

Write-Host "Creating LiteLLM venv..." -ForegroundColor Cyan
python -m venv $venv
if ($LASTEXITCODE -ne 0) { throw "python -m venv failed. Is Python 3.12 installed?" }

Write-Host "Installing litellm[proxy]..." -ForegroundColor Cyan
& "$venv\Scripts\pip.exe" install -r "$repo\tools\litellm-requirements.txt" --quiet
if ($LASTEXITCODE -ne 0) { throw "pip install failed." }

Write-Host "LiteLLM installed at tools/venv-litellm/" -ForegroundColor Green
Write-Host "Start proxy: bob litellm   (listens on http://localhost:8081/v1)" -ForegroundColor DarkGray
