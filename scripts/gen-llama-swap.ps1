#requires -Version 7
# GENERATE config/llama-swap.yaml from config/models.psd1 (the single source of truth).
# Deterministic, idempotent. Re-run any time; also runs automatically on `llm serve`.
#   .\scripts\gen-llama-swap.ps1            # active profile (or $env:LLM_PROFILE)
#   .\scripts\gen-llama-swap.ps1 12gb       # a specific profile
param([string]$Profile)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_models.ps1"

$repo = Split-Path $PSScriptRoot -Parent
$out  = Join-Path $repo 'config\llama-swap.yaml'

$resolved = Get-Models -Profile $Profile
$name     = $resolved.profile
$cfg      = $resolved.config
$models   = $resolved.models

# --- build macros from defaults (overrides the empty placeholder values in models.psd1) ---
$d = $cfg.defaults
if (-not $d) { throw 'models.psd1 is missing the defaults block. Add it per MODULE-A docs.' }

$ngl   = if ($null -ne $d.ngl)   { $d.ngl }   else { 99 }
$fa    = if ($d.flashAttn -ne $false) { '--flash-attn on' } else { '' }
$batch = if ($d.batch -and $d.batch -ne 512)  { "-b $($d.batch)" }   else { '' }
$par   = if ($d.parallel -and $d.parallel -gt 1) { "-np $($d.parallel)" } else { '' }
$thr   = if ($d.threads -and $d.threads -gt 0)   { "-t $($d.threads)" }   else { '' }
$srvParts = @(
    '${env.LLAMA_LOCAL_ROOT}/bin/llama-server.exe',
    '--port ${PORT}',
    "-ngl $ngl",
    $fa, $batch, $par, $thr
) | Where-Object { $_ -ne '' }
$cfg.macros['srv'] = $srvParts -join ' '

$kvQuant = if ($null -ne $d.kvQuant) { $d.kvQuant } else { 'q8_0' }
$cfg.macros['kv'] = if ($kvQuant) { "--cache-type-k $kvQuant --cache-type-v $kvQuant" } else { '' }

# --- format helpers (InvariantCulture so 0.7 never becomes "0,7" on EU locales) ---
$inv = [System.Globalization.CultureInfo]::InvariantCulture
function Fmt($v) {
  if     ($v -is [bool])   { return $v.ToString().ToLower() }
  elseif ($v -is [double] -or $v -is [single]) { return $v.ToString($inv) }
  elseif ($v -is [int] -or $v -is [long])      { return $v.ToString($inv) }
  else   { return [string]$v }
}
function Assert-NoQuote($s, $what) { if ($s -match '"') { throw "value for $what contains a double-quote, which would break the generated YAML: $s" } }

# --- build each model's cmd string (order matters; mirrors the hand-written config) ---
$roleNames = $models.role
foreach ($m in $models) {
  Assert-NoQuote $m.gguf "model '$($m.role)' gguf"
  if ($m.gguf -match 'gemma' -and $m.kv -eq $true) {
    Write-Warning "[$($m.role)] Gemma model with kv=`$true — KV quant causes quality regression. Set kvQuant='' in config/user.psd1 or set kv=`$false on the model."
  }
  $parts = @('${srv}', "-m `${env.LLAMA_LOCAL_ROOT}/models/$($m.gguf)")
  if ($null -ne $m.ctx)              { $parts += "-c $(Fmt $m.ctx)" }
  if ($m.kv)                         { $parts += '${kv}' }
  if ($m.embedding)                  { $parts += '--embedding' }
  if ($m.flags) { foreach ($f in $m.flags) { Assert-NoQuote $f "model '$($m.role)' flag"; $parts += [string]$f } }
  $m | Add-Member -NotePropertyName _cmd -NotePropertyValue ($parts -join ' ')
}

# --- group assertions (catch hand-edit mistakes in the PSD1) ---
$members = @($cfg.group.members)
foreach ($mem in $members) {
  if ($roleNames -notcontains $mem) { throw "group member '$mem' is not a model in profile '$name'" }
  $mObj = $models | Where-Object role -eq $mem
  if ($mObj.pinned) { throw "model '$mem' is pinned but also listed in group.members — pinned models must stay out of the swap group" }
}

# --- emit YAML (deterministic; matches the schema llama-swap reads) ---
$sb = [System.Text.StringBuilder]::new()
$nl = "`n"
[void]$sb.Append("# =============================================================$nl")
[void]$sb.Append("#  GENERATED - DO NOT EDIT.  Source: config/models.psd1$nl")
[void]$sb.Append("#  Regenerate: scripts/gen-llama-swap.ps1  (also runs on ``llm serve``)$nl")
[void]$sb.Append("#  Active profile: $name$nl")
[void]$sb.Append("# =============================================================$nl$nl")

# macros (srv, kv first, then any extras alphabetically)
[void]$sb.Append("macros:$nl")
$macroOrder = @('srv', 'kv') + @($cfg.macros.Keys | Where-Object { $_ -ne 'srv' -and $_ -ne 'kv' } | Sort-Object)
foreach ($k in $macroOrder) {
  if (-not $cfg.macros.Contains($k)) { continue }
  $val = [string]$cfg.macros[$k]
  Assert-NoQuote $val "macro '$k'"
  [void]$sb.Append("  ${k}: `"$val`"$nl")
}
[void]$sb.Append($nl)

# models
[void]$sb.Append("models:$nl")
foreach ($m in $models) {
  [void]$sb.Append("  $($m.role):$nl")
  [void]$sb.Append("    cmd: `"$($m._cmd)`"$nl")
  if ($m.setParams) {
    $pairs = @($m.setParams.Keys | Sort-Object | ForEach-Object { "${_}: $(Fmt $m.setParams[$_])" }) -join ', '
    [void]$sb.Append("    filters:$nl")
    [void]$sb.Append("      setParams: { $pairs }$nl")
  }
  if ($null -ne $m.ttl) { [void]$sb.Append("    ttl: $(Fmt $m.ttl)$nl") }
  [void]$sb.Append($nl)
}

# groups
[void]$sb.Append("groups:$nl")
[void]$sb.Append("  $($cfg.group.name):$nl")
[void]$sb.Append("    swap: $(Fmt $cfg.group.swap)$nl")
[void]$sb.Append("    members: [$(@($members) -join ', ')]$nl")

Set-Content -LiteralPath $out -Value $sb.ToString() -NoNewline -Encoding utf8
Write-Host "generated $out  (profile: $name)" -ForegroundColor Green
