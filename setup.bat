@echo off
REM ============================================================================
REM  local-llm master setup. Run ONCE after cloning. Idempotent (safe to re-run).
REM  Installs prereqs (CUDA 12.8, Python 3.12, Go) -> builds engine+proxy ->
REM  creates venvs + installs tools -> fetches models -> wires Continue/aider.
REM
REM  Usage:   setup.bat                 (full)
REM           setup.bat -SkipModels     (skip the ~38GB model downloads)
REM           setup.bat -Profile 12gb   (smaller models for ~12GB VRAM; see config\models.psd1)
REM           setup.bat -Launch         (start the stack when done)
REM ============================================================================
setlocal
where pwsh >nul 2>nul || (
  echo [setup] PowerShell 7 ^(pwsh^) is required. Install it with:  winget install Microsoft.PowerShell
  exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\setup.ps1" %*
exit /b %ERRORLEVEL%
