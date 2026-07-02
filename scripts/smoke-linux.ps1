#requires -Version 7
# ND2 — back-compat shim. The end-to-end smoke was promoted to the shared cross-OS scripts/smoke.ps1
# (it was always OS-agnostic; only the name said "linux"). This forwarder keeps older references
# (docs, NC7 muscle memory) working. Prefer `scripts/smoke.ps1` directly.
param([switch]$Up, [int]$TimeoutSec = 120)
& "$PSScriptRoot\smoke.ps1" @PSBoundParameters
exit $LASTEXITCODE
