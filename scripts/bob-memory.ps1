#requires -Version 7
# Wrapper: runs bob_memory.py inside venv-litellm.
# Reads memory.dbPath from config/bob.psd1 and passes it as --db.
# Usage: bob-memory.ps1 <store|recall|status|clear|init-profile> [args]
$repo   = Split-Path $PSScriptRoot -Parent
$py     = Join-Path $repo 'tools\venv-litellm\Scripts\python.exe'
$script = Join-Path $PSScriptRoot 'bob_memory.py'

if (-not (Test-Path $py)) {
  Write-Error "venv-litellm python not found: $py  (run scripts/bootstrap-litellm.ps1 first)"
  exit 1
}

. "$PSScriptRoot\_models.ps1"
try {
  $bobCfg = Get-BobConfig
  $dbRel  = ($bobCfg.memory.dbPath ?? 'data\bob.db') -replace '/', '\'
  $dbPath = Join-Path $repo $dbRel
} catch {
  $dbPath = Join-Path $repo 'data\bob.db'
}

& $py $script --db $dbPath @args
