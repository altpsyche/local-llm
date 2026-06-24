#requires -Version 7
# Shared model-registry helpers. Single source of truth = config/models.psd1.
# Dot-source from another script:  . "$PSScriptRoot\_models.ps1"
#
# Exposes:
#   Get-ModelsConfig            -> raw hashtable from the PSD1
#   Resolve-ProfileName [-Profile n]  -> profile name (arg -> $env:LLM_PROFILE -> activeProfile)
#   Get-Models [-Profile n]     -> @{ profile; config; models } ; models = ordered role objects
#   Set-ActiveProfile -Name n   -> rewrite the activeProfile line in place (validated)

$script:ModelsRepo = Split-Path $PSScriptRoot -Parent
$script:ModelsFile = Join-Path $script:ModelsRepo 'config\models.psd1'

function Get-ModelsConfig {
  if (-not (Test-Path $script:ModelsFile)) { throw "models config not found: $script:ModelsFile" }
  return Import-PowerShellDataFile -LiteralPath $script:ModelsFile
}

function Resolve-ProfileName {
  param([string]$Profile, $Config)
  if (-not $Config) { $Config = Get-ModelsConfig }
  $name = if     ($Profile)          { $Profile }
          elseif ($env:LLM_PROFILE)  { $env:LLM_PROFILE }
          else                       { $Config.activeProfile }
  if (-not $Config.profiles.Contains($name)) {
    throw "unknown profile '$name'. Valid: $($Config.profiles.Keys -join ', ')"
  }
  return $name
}

function Get-Models {
  # Resolve a profile and return its models as ordered role objects (roles only —
  # '_'-prefixed metadata keys are skipped). Stable order so generated output is
  # deterministic regardless of PSD1 hashtable enumeration order.
  param([string]$Profile)
  $cfg   = Get-ModelsConfig
  $name  = Resolve-ProfileName -Profile $Profile -Config $cfg
  $prof  = $cfg.profiles[$name]
  $order = @('planner', 'coder', 'chat', 'fim', 'embed')
  $roles = @($prof.Keys | Where-Object { -not $_.StartsWith('_') })

  $sorted = @()
  foreach ($r in $order) { if ($roles -contains $r) { $sorted += $r } }
  $sorted += @($roles | Where-Object { $order -notcontains $_ } | Sort-Object)

  $list = foreach ($r in $sorted) {
    $m = $prof[$r].Clone()        # shallow copy so we don't mutate the loaded config
    $m['role'] = $r
    [pscustomobject]$m
  }
  return @{ profile = $name; config = $cfg; models = @($list) }
}

function Get-GpuVramGB {
  # Total VRAM of GPU 0 in whole GB via nvidia-smi; $null if nvidia-smi is absent/unparseable.
  if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) { return $null }
  try {
    $mib = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1
    if ("$mib".Trim() -match '^\d+$') { return [int][math]::Round([int]$mib / 1024) }
  } catch {}
  return $null
}

function Get-SuggestedProfile {
  # Largest '<N>gb' profile whose N <= detected VRAM (auto-scales as 32gb/64gb are added).
  # Falls back to the smallest sized profile if the card is below them all. $null if no GPU info.
  param([int]$VramGB)
  if (-not $VramGB) { $VramGB = Get-GpuVramGB }
  if (-not $VramGB) { return $null }
  $cfg = Get-ModelsConfig
  $sized = foreach ($p in $cfg.profiles.Keys) {
    if ($p -match '^(\d+)gb$') { [pscustomobject]@{ name = $p; gb = [int]$matches[1] } }
  }
  if (-not $sized) { return $null }
  $fit = $sized | Where-Object { $_.gb -le $VramGB } | Sort-Object gb -Descending | Select-Object -First 1
  if ($fit) { return $fit.name }
  return ($sized | Sort-Object gb | Select-Object -First 1).name
}

function Set-ActiveProfile {
  param([Parameter(Mandatory)][string]$Name)
  $cfg = Get-ModelsConfig
  if (-not $cfg.profiles.Contains($Name)) {
    throw "unknown profile '$Name'. Valid: $($cfg.profiles.Keys -join ', ')"
  }
  if ($cfg.activeProfile -eq $Name) {
    Write-Host "activeProfile already '$Name'" -ForegroundColor DarkGray; return
  }
  $raw = Get-Content -Raw -LiteralPath $script:ModelsFile
  $new = [regex]::Replace($raw, "(?m)^(\s*activeProfile\s*=\s*)'[^']*'", "`${1}'$Name'")
  if ($new -eq $raw) { throw "no 'activeProfile = ...' line found to update in $script:ModelsFile" }
  Set-Content -LiteralPath $script:ModelsFile -Value $new -NoNewline -Encoding utf8
  Write-Host "activeProfile -> '$Name'  ($script:ModelsFile)" -ForegroundColor Green
}
