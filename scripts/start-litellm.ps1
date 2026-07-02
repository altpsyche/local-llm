#requires -Version 7
# Start the LiteLLM proxy.
# Foreground (default): shows logs in this terminal, Ctrl+C to stop.
# Background (-NoWindow): starts hidden, logs to logs/litellm.log, PID to logs/litellm.pid.
param([switch]$NoWindow)
$ErrorActionPreference = "Stop"
$repo  = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\_models.ps1"
$proxy = Get-VenvExe -Venv 'venv-litellm' -Exe 'litellm'   # NC4: OS-aware (Scripts\litellm.exe | bin/litellm)
$cfg   = Join-Path $repo 'config\litellm.yaml'

if (-not (Test-Path $proxy)) {
    throw "LiteLLM not installed — run: .\scripts\bootstrap-litellm.ps1"
}

$d    = (Get-ModelsConfig).defaults
$port = $d.litellmPort ?? (Get-BobPortDefault 'litellmPort')

$pidFile = Join-Path $repo 'logs\litellm.pid'
if (Test-Path $pidFile) {
    $existingPid = [int](Get-Content $pidFile -Raw -ErrorAction SilentlyContinue)
    if ($existingPid -and (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) {
        Write-Host "LiteLLM already running (PID $existingPid) at http://localhost:$port/v1" -ForegroundColor DarkGray
        return
    }
    Remove-Item $pidFile  # stale PID file
}

$env:PYTHONUTF8 = '1'   # LiteLLM banner has Unicode chars; cp1252 (Windows default) can't encode them

if ($NoWindow) {
    $logsDir = Join-Path $repo 'logs'
    if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory $logsDir | Out-Null }
    $logFile = Join-Path $logsDir 'litellm.log'
    $cmd = '$env:PYTHONUTF8=''1''; ' + "& '$proxy' --config '$cfg' --port $port 2>&1 | Tee-Object -FilePath '$logFile'"
    $launchPid = Start-BobBackgroundProcess -ArgList @("-NonInteractive", "-Command", $cmd) -PidFile $pidFile
    Write-Host "LiteLLM proxy: http://localhost:$port/v1   (PID $launchPid)" -ForegroundColor Green
    Write-Host "Logs: logs/litellm.log   Stop: bob litellm stop" -ForegroundColor DarkGray
} else {
    Write-Host "LiteLLM proxy starting on http://localhost:$port/v1 (Ctrl+C to stop)" -ForegroundColor Cyan
    & $proxy --config $cfg --port $port
}
