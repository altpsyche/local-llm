@echo off
REM ============================================================================
REM  Bob prerequisite installer. Run ONCE on a fresh machine.
REM  Installs: Node.js, uv, Go, Python 3.12, CUDA Toolkit, cmake, Docker Desktop.
REM
REM  After this script finishes:
REM    - If Docker Desktop was just installed: LOG OUT and back in, then run setup.bat
REM    - If Docker was already installed: run setup.bat directly
REM
REM  Manual prereqs (install before running this):
REM    Git          https://git-scm.com
REM    Scoop        irm get.scoop.sh | iex   (in PowerShell)
REM    VS2022 C++   winget install Microsoft.VisualStudio.2022.Community
REM                 (then: VS Installer -> Modify -> Desktop development with C++)
REM    PowerShell 7 winget install Microsoft.PowerShell
REM ============================================================================
setlocal
REM ND4 — version-stamp: state which Bob release this blessed entry belongs to.
set "BOBVER=?"
if exist "%~dp0VERSION" set /p BOBVER=<"%~dp0VERSION"
echo [install_prereqs] Bob %BOBVER% - prerequisite install
where pwsh >nul 2>nul || (
    echo [install_prereqs] PowerShell 7 ^(pwsh^) is required.
    echo Install it with:  winget install Microsoft.PowerShell
    exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install-prereqs.ps1" %*
exit /b %ERRORLEVEL%
