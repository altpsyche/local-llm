#requires -Version 7
# Launch the whole stack in separate windows:
#   - llama-swap endpoint (OpenAI-compatible) on the configured port
#   - Open WebUI on the configured webuiPort, pre-wired to the endpoint + RAG embeddings
# Close a window (or Ctrl+C in it) to stop that service.
$ErrorActionPreference = "Stop"
$repo  = Split-Path $PSScriptRoot -Parent
$webui = Join-Path $repo "tools\venv-webui\Scripts\open-webui.exe"
. "$PSScriptRoot\_models.ps1"
$cfg        = Get-ModelsConfig
$port       = $cfg.defaults.port ?? 8080
$webuiPort  = $cfg.defaults.webuiPort ?? 3000
$secret     = $cfg.defaults.webuiSecret ?? 'local-llm-dev'

# 1) endpoint
Start-Process pwsh -ArgumentList "-NoExit","-File","$repo\scripts\start.ps1"

# 2) Open WebUI, with the local connection + embedding model set via env (applied on first run)
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
  Start-Process pwsh -ArgumentList "-NoExit","-Command","$owEnv & '$webui' serve --port $webuiPort"
  Write-Host "Open WebUI: http://localhost:$webuiPort   (first launch takes ~20s)" -ForegroundColor Green
} else {
  Write-Warning "open-webui not found — run scripts\bootstrap.ps1 first. Skipping Open WebUI."
}
Write-Host "Endpoint:   http://localhost:$port/v1" -ForegroundColor Green
Write-Host "aider (plan!=edit):  tools\venv-aider\Scripts\aider   (config auto-loaded from ~/.aider.conf.yml after setup-clients.ps1)" -ForegroundColor DarkGray
