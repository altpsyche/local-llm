#requires -Version 7
# Show token/cost usage summary from LiteLLM budget tracking.
$ErrorActionPreference = 'SilentlyContinue'
$repo = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\_models.ps1"
$d    = (Get-ModelsConfig).defaults
$port = $d.litellmPort ?? (Get-BobPortDefault 'litellmPort')
$base = "http://localhost:$port"

# --- Config limits from litellm.yaml ---
$cfgFile = Join-Path $repo 'config\litellm.yaml'
$maxBudget = $null; $budgetDuration = $null
if (Test-Path $cfgFile) {
  $raw = Get-Content $cfgFile -Raw
  if ($raw -match 'max_budget:\s*(\S+)')    { $maxBudget      = $Matches[1] }
  if ($raw -match 'budget_duration:\s*"?([^"\r\n]+)"?') { $budgetDuration = $Matches[1].Trim() }
}

Write-Host ""
Write-Host "Bob Budget" -ForegroundColor Cyan
Write-Host ("-" * 40)

# --- LiteLLM health + spend ---
$litellmUp = $false
$spend = $null
try {
  $health = Invoke-RestMethod "$base/health" -TimeoutSec 3
  $litellmUp = $true
} catch {}

if ($litellmUp) {
  # Try the LiteLLM /spend/logs endpoint (available when database_url is configured)
  try {
    $spend = Invoke-RestMethod "$base/spend/logs" -TimeoutSec 5
  } catch {}

  # Try the global spend info
  try {
    $global = Invoke-RestMethod "$base/global/spend" -TimeoutSec 5
    if ($global) {
      Write-Host ("{'0',-20} {1}" -f 'Spend (all-time)', "`$$([math]::Round($global.spend, 4))")
    }
  } catch {}
} else {
  Write-Host "LiteLLM not running — start with: bob litellm" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Configured limits:"
if ($maxBudget)      { Write-Host ("  {0,-18} `${1}" -f "Max budget:", $maxBudget) }
if ($budgetDuration) { Write-Host ("  {0,-18} {1}" -f "Period:", $budgetDuration) }

# --- Local memory DB size (always $0 cost) ---
$dbPath = Join-Path $repo 'data\bob.db'
if (Test-Path $dbPath) {
  $dbKb = [math]::Round((Get-Item $dbPath).Length / 1KB, 1)
  Write-Host ""
  Write-Host "Local memory DB: $dbPath ($dbKb KB)  [cost: `$0 — fully local]" -ForegroundColor DarkGray
}

# --- Langfuse link if configured ---
$langfusePort = $d.langfusePort ?? (Get-BobPortDefault 'langfusePort')
try {
  Invoke-RestMethod "http://localhost:$langfusePort/api/public/health" -TimeoutSec 2 | Out-Null
  Write-Host ""
  Write-Host "Langfuse tracing: http://localhost:$langfusePort  (detailed per-request logs)" -ForegroundColor DarkGray
} catch {}

Write-Host ""
