#requires -Version 7
# Shared helpers — dot-sourced by setup.ps1 and install-prereqs.ps1.

function Have($n) { [bool](Get-Command $n -ErrorAction SilentlyContinue) }

function Install-WithWinget {
    param([string]$Package, [string[]]$ExtraArgs = @())
    winget install $Package @ExtraArgs `
        --accept-package-agreements --accept-source-agreements --disable-interactivity
    # -1978335189 (0x8A150011 as signed int32) = APPINSTALLER_CLI_ERROR_PACKAGE_ALREADY_INSTALLED
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        throw "winget install $Package failed (exit $LASTEXITCODE)"
    }
}
