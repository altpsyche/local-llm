#requires -Version 7
# Launch the llama-swap endpoint (OpenAI-compatible) on :8080.
$ErrorActionPreference = "Stop"
$repo   = Split-Path $PSScriptRoot -Parent
$swap   = Join-Path $repo "bin\llama-swap.exe"
$config = Join-Path $repo "config\llama-swap.yaml"

if (-not (Test-Path $swap))   { throw "llama-swap.exe missing. Run scripts\build-llama-swap.ps1 (or drop the release binary in bin\)." }
if (-not (Test-Path $config)) { throw "config missing: $config" }

Write-Host "Endpoint: http://localhost:8080/v1   (Ctrl+C to stop)" -ForegroundColor Green
& $swap --config $config --listen :8080
