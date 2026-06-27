#requires -Version 7
# Start endpoint + Open WebUI silently in the background (no terminal popups).
# Use 'llm serve' for interactive/foreground mode with live log output.
param([switch]$NoOpen, [switch]$WithServices)
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

$spin = [char[]]@('|','/','-','\')
$sw   = [Diagnostics.Stopwatch]::StartNew()
$i    = 0; $up = $false
while ($sw.Elapsed.TotalSeconds -lt 60) {
    try { Invoke-RestMethod "http://localhost:$port/v1/models" -ErrorAction Stop | Out-Null; $up = $true; break }
    catch {}
    if ($swapProc.HasExited) { Write-Warning "Endpoint process exited. Check: llm logs"; break }
    Write-Host "`r  $($spin[$i++ % 4]) Starting endpoint..." -NoNewline -ForegroundColor DarkGray
    Start-Sleep -Milliseconds 200
}
if ($up) { Write-Host "`r  Endpoint ready ($([int]$sw.Elapsed.TotalSeconds)s)              " -ForegroundColor Green }
else      { Write-Warning "Endpoint did not respond in 60s. Check: llm logs" }

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
  Write-Host "Open WebUI: http://localhost:$webuiPort   (PID $($uiProc.Id))" -ForegroundColor Green
  if (-not $NoOpen) {
    $sw2 = [Diagnostics.Stopwatch]::StartNew(); $j = 0; $uiUp = $false
    while ($sw2.Elapsed.TotalSeconds -lt 120) {
        # TCP check: just verify the port is listening (avoids HTTP status-code false failures)
        try {
            $tcp = [System.Net.Sockets.TcpClient]::new()
            $tcp.Connect('127.0.0.1', $webuiPort)
            $tcp.Close()
            $uiUp = $true; break
        } catch {}
        # Bail early if the host process died
        if ($uiProc.HasExited) {
            Write-Warning "Open WebUI process exited. Check: llm logs"; break
        }
        Write-Host "`r  $($spin[$j++ % 4]) Starting Open WebUI..." -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Milliseconds 500
    }
    if ($uiUp) {
        Write-Host "`r  Open WebUI ready ($([int]$sw2.Elapsed.TotalSeconds)s)           " -ForegroundColor Green
        Start-Process "http://localhost:$webuiPort"
    } else { Write-Warning "Open WebUI didn't respond. Open manually: http://localhost:$webuiPort" }
  }
} else {
  Write-Warning "open-webui not found — run scripts\bootstrap.ps1 first. Skipping Open WebUI."
}
if ($WithServices) {
  if (Get-Command docker -ErrorAction SilentlyContinue) {
    Write-Host "Starting Docker services..." -ForegroundColor Cyan
    $compose  = "$repo\tools\compose\docker-compose.yml"
    $envFile  = "$repo\tools\compose\.env"
    @"
REPO_PATH=$repo
LANGFUSE_PORT=$($cfg.defaults.langfusePort ?? 3001)
SEARXNG_PORT=$($cfg.defaults.searxngPort ?? 8888)
N8N_PORT=$($cfg.defaults.n8nPort ?? 5678)
"@ | Set-Content $envFile -Encoding utf8
    docker compose -f $compose up -d 2>$null
    Write-Host "Services started:" -ForegroundColor Green
    docker compose -f $compose ps --format json 2>$null | ConvertFrom-Json | ForEach-Object {
        $state = if ($_.Health) { $_.Health } else { $_.State }
        $color = if ($state -eq 'healthy') { 'Green' } else { 'DarkGray' }
        Write-Host ("  {0,-40} {1}" -f $_.Name, $state) -ForegroundColor $color
    }
  } else {
    Write-Warning "-WithServices: Docker not found. Run .\scripts\setup-docker.ps1 first."
  }
}
Write-Host "aider: llm aider   stop: llm stop   status: llm status   logs: llm logs" -ForegroundColor DarkGray
