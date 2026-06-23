#requires -Version 7
# Launch the whole stack in separate windows:
#   - llama-swap endpoint (OpenAI-compatible) on :8080
#   - Open WebUI on :3000, pre-wired to the endpoint + RAG embeddings (no manual UI setup)
# Close a window (or Ctrl+C in it) to stop that service.
$ErrorActionPreference = "Stop"
$repo  = Split-Path $PSScriptRoot -Parent
$webui = Join-Path $repo "tools\venv-webui\Scripts\open-webui.exe"

# 1) endpoint
Start-Process pwsh -ArgumentList "-NoExit","-File","$repo\scripts\start.ps1"

# 2) Open WebUI, with the local connection + embedding model set via env (applied on first run)
if (Test-Path $webui) {
  $owEnv = @(
    "`$env:OPENAI_API_BASE_URL='http://localhost:8080/v1';",
    "`$env:OPENAI_API_KEY='sk-local';",
    "`$env:RAG_EMBEDDING_ENGINE='openai';",
    "`$env:RAG_OPENAI_API_BASE_URL='http://localhost:8080/v1';",
    "`$env:RAG_OPENAI_API_KEY='sk-local';",
    "`$env:RAG_EMBEDDING_MODEL='embed';"
  ) -join ""
  Start-Process pwsh -ArgumentList "-NoExit","-Command","$owEnv & '$webui' serve --port 3000"
  Write-Host "Open WebUI: http://localhost:3000   (first launch takes ~20s)" -ForegroundColor Green
} else {
  Write-Warning "open-webui not found — run scripts\bootstrap.ps1 first. Skipping Open WebUI."
}
Write-Host "Endpoint:   http://localhost:8080/v1" -ForegroundColor Green
Write-Host "aider (plan!=edit):  tools\venv-aider\Scripts\aider   (config auto-loaded from ~/.aider.conf.yml after setup-clients.ps1)" -ForegroundColor DarkGray
