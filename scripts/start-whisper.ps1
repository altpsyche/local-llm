#requires -Version 7
# Start the whisper.cpp STT server.
# Foreground (default): shows logs in this terminal, Ctrl+C to stop.
# Background (-NoWindow): starts hidden, logs to logs/whisper.log, PID to logs/whisper.pid.
param([switch]$NoWindow)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$exe  = Join-Path $repo 'bin\whisper-server.exe'
$mdl  = Join-Path $repo 'models\whisper\ggml-base.en.bin'

if (-not (Test-Path $exe)) {
    throw "whisper-server.exe not found — run: bob setup-voice"
}
if (-not (Test-Path $mdl)) {
    throw "Whisper model not found at $mdl — run: bob setup-voice"
}

. "$PSScriptRoot\_models.ps1"
$bobCfg  = Get-BobConfig
$sttPort = $bobCfg.voice.sttPort ?? 8082

$pidFile = Join-Path $repo 'logs\whisper.pid'
if (Test-Path $pidFile) {
    $existingPid = [int](Get-Content $pidFile -Raw -ErrorAction SilentlyContinue)
    if ($existingPid -and (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) {
        Write-Host "whisper-server already running (PID $existingPid) at http://localhost:$sttPort" -ForegroundColor DarkGray
        return
    }
    Remove-Item $pidFile  # stale PID file
}

if ($NoWindow) {
    $logsDir = Join-Path $repo 'logs'
    if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory $logsDir | Out-Null }
    $logFile = Join-Path $logsDir 'whisper.log'
    $cmd = "& '$exe' --model '$mdl' --port $sttPort --host 0.0.0.0 2>&1 | Tee-Object -FilePath '$logFile'"
    $proc = Start-Process pwsh `
        -ArgumentList @("-NonInteractive", "-Command", $cmd) `
        -WindowStyle Hidden -PassThru
    $proc.Id | Set-Content $pidFile -Encoding utf8
    Write-Host "whisper-server: http://localhost:$sttPort   (PID $($proc.Id))" -ForegroundColor Green
    Write-Host "Logs: logs/whisper.log   Stop: bob whisper stop" -ForegroundColor DarkGray

    # Poll for readiness (TCP connect) so callers know the server is accepting requests
    $ready = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $tcp = [Net.Sockets.TcpClient]::new('127.0.0.1', $sttPort)
            $tcp.Close()
            $ready = $true
            break
        } catch {}
    }
    if (-not $ready) { Write-Warning "whisper-server may not be ready yet on port $sttPort — check logs/whisper.log" }
} else {
    Write-Host "whisper-server starting on http://localhost:$sttPort (Ctrl+C to stop)" -ForegroundColor Cyan
    & $exe --model $mdl --port $sttPort --host 0.0.0.0
}
