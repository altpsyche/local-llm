#requires -Version 7
# Start the piper TTS HTTP server (OpenAI-compatible /v1/audio/speech endpoint).
# Foreground (default): shows logs in this terminal, Ctrl+C to stop.
# Background (-NoWindow): starts hidden, logs to logs/piper.log, PID to logs/piper.pid.
param([switch]$NoWindow)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent

. "$PSScriptRoot\_models.ps1"
$bobCfg   = Get-BobConfig
$ttsPort  = $bobCfg.voice.ttsPort  ?? (Get-BobPortDefault 'ttsPort')
$ttsVoice = $bobCfg.voice.ttsVoice ?? 'en_GB-alan-medium'

$piperExe  = Get-BinExe -Base 'piper'                         # NC4: bin\piper.exe | bin/piper
$voicePath = Join-Path $repo "bin\voices\$ttsVoice.onnx"
$pyExe     = Get-VenvExe -Venv 'venv-litellm' -Exe 'python'  # NC4: Scripts\python.exe | bin/python
$serverScript = Join-Path $repo 'scripts\piper_server.py'

if (-not (Test-Path $piperExe))  { throw "piper.exe not found — run: bob setup-voice" }
if (-not (Test-Path $voicePath)) { throw "Voice model not found at $voicePath — run: bob setup-voice" }
if (-not (Test-Path $pyExe))     { throw "venv-litellm not found — run: scripts\bootstrap-litellm.ps1" }

$pidFile = Join-Path $repo 'logs\piper.pid'
if (Test-Path $pidFile) {
    $existingPid = [int](Get-Content $pidFile -Raw -ErrorAction SilentlyContinue)
    if ($existingPid -and (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) {
        Write-Host "piper-server already running (PID $existingPid) at http://localhost:$ttsPort" -ForegroundColor DarkGray
        return
    }
    Remove-Item $pidFile  # stale PID file
}

$env:PIPER_EXE   = $piperExe
$env:PIPER_VOICE = $voicePath
$env:PIPER_PORT  = $ttsPort

if ($NoWindow) {
    $logsDir = Join-Path $repo 'logs'
    if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory $logsDir | Out-Null }
    $logFile = Join-Path $logsDir 'piper.log'
    $cmd = "`$env:PIPER_EXE='$piperExe'; `$env:PIPER_VOICE='$voicePath'; `$env:PIPER_PORT='$ttsPort'; & '$pyExe' '$serverScript' 2>&1 | Tee-Object -FilePath '$logFile'"
    $launchPid = Start-BobBackgroundProcess -ArgList @("-NonInteractive", "-Command", $cmd) -PidFile $pidFile
    Write-Host "piper-server:  http://localhost:$ttsPort   (PID $launchPid)" -ForegroundColor Green
    Write-Host "Voice: $ttsVoice   Logs: logs/piper.log   Stop: bob piper stop" -ForegroundColor DarkGray

    # Poll for readiness — FastAPI/uvicorn takes longer to start than a C++ binary
    $ready = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $tcp = [Net.Sockets.TcpClient]::new('127.0.0.1', $ttsPort)
            $tcp.Close()
            $ready = $true
            break
        } catch {}
    }
    if (-not $ready) { Write-Warning "piper-server may not be ready on port $ttsPort — check logs/piper.log" }
} else {
    Write-Host "piper-server starting on http://localhost:$ttsPort  voice=$ttsVoice  (Ctrl+C to stop)" -ForegroundColor Cyan
    & $pyExe $serverScript
}
