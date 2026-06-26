#requires -Version 7
# Install Docker Desktop (if needed) and start the services stack (Module H).
# Ports are read from config/models.psd1 defaults (override via config/user.psd1).
#
# Services started:
#   Langfuse  — LLM observability       (default :3001)
#   SearXNG   — private web search      (default :8888)
#   n8n       — workflow automation     (default :5678)
#
# Run once to install. Afterwards: llm services start|stop|status|logs
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent

# 1. Install Docker Desktop if not present
$docker = Get-Command docker -ErrorAction SilentlyContinue
if (-not $docker) {
    Write-Host "Installing Docker Desktop via winget..." -ForegroundColor Cyan
    winget install Docker.DockerDesktop --accept-package-agreements --accept-source-agreements
    Write-Warning @"
Docker Desktop installed.
ACTION REQUIRED: Log out and back in (or restart), then re-run:
    .\scripts\setup-docker.ps1
"@
    return
}

# 2. Wait for Docker daemon
Write-Host "Checking Docker daemon..." -ForegroundColor Cyan
$timeout = 90; $elapsed = 0
while ($elapsed -lt $timeout) {
    if (docker info 2>$null) { break }
    if ($elapsed -eq 0) {
        $ddExe = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
        if (Test-Path $ddExe) { Start-Process $ddExe -WindowStyle Minimized }
        Write-Host "  Starting Docker Desktop..." -ForegroundColor DarkGray
    }
    Start-Sleep -Seconds 5; $elapsed += 5
    Write-Host "  Waiting... ($elapsed/$timeout s)" -ForegroundColor DarkGray
}
if (-not (docker info 2>$null)) {
    throw "Docker daemon did not respond within ${timeout}s. Launch Docker Desktop manually and re-run."
}
Write-Host "  Docker ready." -ForegroundColor Green

# 3. Read ports from models.psd1 (respects user.psd1 overrides via Get-ModelsConfig)
. "$PSScriptRoot\_models.ps1"
$d = (Get-ModelsConfig).defaults
$langfusePort = $d.langfusePort ?? 3001
$searxngPort  = $d.searxngPort  ?? 8888
$n8nPort      = $d.n8nPort      ?? 5678

# 4. Write .env for docker-compose
$envFile = "$repo\tools\compose\.env"
@"
REPO_PATH=$repo
LANGFUSE_PORT=$langfusePort
SEARXNG_PORT=$searxngPort
N8N_PORT=$n8nPort
"@ | Set-Content $envFile -Encoding utf8
Write-Host "  Ports: Langfuse=$langfusePort  SearXNG=$searxngPort  n8n=$n8nPort" -ForegroundColor DarkGray

# 5. Create data directories (gitignored)
@('langfuse-data', 'n8n-data') | ForEach-Object {
    $d2 = Join-Path $repo "tools\$_"
    if (-not (Test-Path $d2)) { New-Item -ItemType Directory -Force $d2 | Out-Null }
}

# 6. Write SearXNG config if absent
$sxDir = Join-Path $repo 'config\searxng'
$sxCfg = Join-Path $sxDir 'settings.yml'
if (-not (Test-Path $sxDir)) { New-Item -ItemType Directory -Force $sxDir | Out-Null }
if (-not (Test-Path $sxCfg)) {
    @'
use_default_settings: true
server:
  secret_key: "local-llm-searxng"
  bind_address: "0.0.0.0:8080"
search:
  safe_search: 0
  default_lang: "en"
'@ | Set-Content $sxCfg -Encoding utf8
}

# 7. Pull images and start stack
$compose = "$repo\tools\compose\docker-compose.yml"
Write-Host "Pulling images (first run may take a few minutes)..." -ForegroundColor Cyan
docker compose -f $compose pull
Write-Host "Starting services..." -ForegroundColor Cyan
docker compose -f $compose up -d

Write-Host ""
Write-Host "Services running:" -ForegroundColor Green
Write-Host "  Langfuse:  http://localhost:$langfusePort  (login: admin@localhost / admin)" -ForegroundColor Green
Write-Host "  SearXNG:   http://localhost:$searxngPort" -ForegroundColor Green
Write-Host "  n8n:       http://localhost:$n8nPort" -ForegroundColor Green
Write-Host ""
Write-Host "Manage:          llm services start|stop|status|logs" -ForegroundColor DarkGray
Write-Host "Change ports:    edit config/user.psd1, re-run .\scripts\setup-docker.ps1" -ForegroundColor DarkGray
Write-Host "Enable tracing:  uncomment langfuse callbacks in config/litellm.yaml" -ForegroundColor DarkGray
