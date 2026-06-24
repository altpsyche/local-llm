#requires -Version 7
# Launch the llama-swap endpoint (OpenAI-compatible) on :8080.
$ErrorActionPreference = "Stop"
$repo   = Split-Path $PSScriptRoot -Parent
$swap   = Join-Path $repo "bin\llama-swap.exe"
$config = Join-Path $repo "config\llama-swap.yaml"

if (-not (Test-Path $swap))   { throw "llama-swap.exe missing. Run scripts\build-llama-swap.ps1 (or drop the release binary in bin\)." }
# Regenerate the runtime config from the single source (config/models.psd1) so edits /
# profile switches always take effect, and a fresh clone always has a config. Sub-second.
& "$PSScriptRoot\gen-llama-swap.ps1"
# portable port-in-use check (Get-NetTCPListener isn't present on all boxes)
$inUse = $false
try { $c = [System.Net.Sockets.TcpClient]::new(); $c.Connect('127.0.0.1', 8080); $inUse = $true; $c.Close() } catch {}
if ($inUse) {
  Write-Warning "Port 8080 already in use — the endpoint is probably already running ('llm stop' to free it)."; return
}

# Expose the repo root to the config so model paths relocate with the clone (see config\llama-swap.yaml).
$env:LLAMA_LOCAL_ROOT = ($repo -replace '\\','/')

Write-Host "Endpoint: http://localhost:8080/v1   (loopback only; Ctrl+C to stop)" -ForegroundColor Green
& $swap --config $config --listen 127.0.0.1:8080
