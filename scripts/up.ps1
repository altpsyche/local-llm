#requires -Version 7
# Start endpoint + Open WebUI silently in the background (no terminal popups).
# Use 'llm serve' for interactive/foreground mode with live log output.
param([switch]$NoOpen)
$ErrorActionPreference = "Stop"
$repo  = Split-Path $PSScriptRoot -Parent
$webui = Join-Path $repo "tools\venv-webui\Scripts\open-webui.exe"
. "$PSScriptRoot\_models.ps1"
$cfg        = Get-ModelsConfig
$port       = $cfg.defaults.port ?? 8080
$webuiPort  = $cfg.defaults.webuiPort ?? 3000
$secret     = $cfg.defaults.webuiSecret ?? 'local-llm-dev'
$logsDir    = Join-Path $repo 'logs'
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory $logsDir | Out-Null }

if (Test-PortInUse -Port $port) {
  Write-Warning "Port $port already in use — endpoint may already be running ('llm stop' to free it)."; return
}

# 1) Endpoint — hidden window, logs to logs/llama-swap.log via start.ps1's Tee-Object
$swapProc = Start-Process pwsh `
    -ArgumentList @("-NonInteractive", "-File", "`"$repo\scripts\start.ps1`"") `
    -WindowStyle Hidden -PassThru
$swapProc.Id | Set-Content (Join-Path $logsDir 'llama-swap.pid') -Encoding utf8
Write-Host "Endpoint:   http://localhost:$port/v1   (PID $($swapProc.Id))" -ForegroundColor Green
Write-Host "            logs: llm logs" -ForegroundColor DarkGray

# 2) Open WebUI — hidden window, log to logs/open-webui.log
if (Test-Path $webui) {
  $owEnv = @(
    "`$env:OPENAI_API_BASE_URL='http://localhost:$port/v1';",
    "`$env:OPENAI_API_KEY='sk-local';",
    "`$env:RAG_EMBEDDING_ENGINE='openai';",
    "`$env:RAG_OPENAI_API_BASE_URL='http://localhost:$port/v1';",
    "`$env:RAG_OPENAI_API_KEY='sk-local';",
    "`$env:RAG_EMBEDDING_MODEL='embed';",
    # keep ALL Open WebUI state inside the (gitignored) repo data dir, not scattered in CWD
    "`$env:DATA_DIR='$repo\tools\webui-data';",
    "`$env:WEBUI_SECRET_KEY='$secret';"
  ) -join ""
  $uiLog = Join-Path $logsDir 'open-webui.log'
  $uiCmd = "$owEnv & '$webui' serve --port $webuiPort 2>&1 | Tee-Object -FilePath '$uiLog'"
  $uiProc = Start-Process pwsh `
      -ArgumentList @("-NonInteractive", "-Command", $uiCmd) `
      -WindowStyle Hidden -PassThru
  $uiProc.Id | Set-Content (Join-Path $logsDir 'open-webui.pid') -Encoding utf8
  Write-Host "Open WebUI: http://localhost:$webuiPort   (PID $($uiProc.Id), first launch ~20s)" -ForegroundColor Green
  if (-not $NoOpen) {
    Start-Sleep -Seconds 2
    Start-Process "http://localhost:$webuiPort"
    Write-Host "Browser opened." -ForegroundColor DarkGray
  }
} else {
  Write-Warning "open-webui not found — run scripts\bootstrap.ps1 first. Skipping Open WebUI."
}
Write-Host "aider: llm aider   stop: llm stop   status: llm status   logs: llm logs" -ForegroundColor DarkGray
