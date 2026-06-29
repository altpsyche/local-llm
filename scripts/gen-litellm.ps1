#requires -Version 7
# Generates config/litellm.yaml from config/models.psd1 (+ user.psd1 overrides).
# Local models route through llama-swap (:8080). Pro models route directly to
# their API provider via litellm's native provider prefixes — no platform fees.
#
# Run automatically on `bob gen` and `bob serve`. Safe to run manually anytime.

param([string]$Profile)

. "$PSScriptRoot\_models.ps1"

$data   = Get-Models -Profile $Profile
$cfg    = $data.config
$models = $data.models
$peers  = Get-EnabledPeers -Config $cfg
$port   = $cfg.defaults.port

$out = [System.Collections.Generic.List[string]]::new()
$out.Add('# GENERATED - DO NOT EDIT.  Source: config/models.psd1')
$out.Add('# Regenerate: scripts/gen-litellm.ps1  (also runs on `bob gen` and `bob serve`)')
$out.Add('')
$out.Add('model_list:')

# Local models — all route through llama-swap
foreach ($m in $models) {
    $out.Add("  - model_name: $($m.role)")
    $out.Add("    litellm_params:")
    $out.Add("      model: openai/$($m.role)")
    $out.Add("      api_base: http://localhost:$port/v1")
    $out.Add("      api_key: sk-local")
}

# Pro models — route directly to each enabled peer's API (no intermediary)
foreach ($peer in $peers) {
    if (-not $peer.pro -or $peer.pro.Keys.Count -eq 0) { continue }

    $keyEnv = $peer.apiKeyEnv
    if ($keyEnv -and -not [System.Environment]::GetEnvironmentVariable($keyEnv)) {
        Write-Warning "gen-litellm: env var '$keyEnv' not set for peer '$($peer.name)' — pro models will fail at request time"
    }

    $prefix = if ($peer.litellmPrefix) { $peer.litellmPrefix } else { 'openai' }
    $proxyUrl = $peer.proxy

    # Emit roles in sorted order for deterministic output
    foreach ($role in ($peer.pro.Keys | Sort-Object)) {
        $roleVal = $peer.pro[$role]
        # Support both string ('model-id') and hashtable (@{ model='...'; maxTokens=N })
        if ($roleVal -is [string]) {
            $modelId  = $roleVal
            $maxToks  = $null
        } else {
            $modelId  = $roleVal.model
            $maxToks  = $roleVal.maxTokens
        }
        $modelStr  = "$prefix/$modelId"
        $roleName  = "$role-pro"

        $out.Add("  - model_name: $roleName")
        $out.Add("    litellm_params:")
        $out.Add("      model: $modelStr")
        if ($proxyUrl) {
            $out.Add("      api_base: $proxyUrl")
        }
        $out.Add("      api_key: os.environ/$keyEnv")
        if ($maxToks) {
            $out.Add("      max_tokens: $maxToks")
        }
    }
}

$out.Add('')
$out.Add('litellm_settings:')
$out.Add('  num_retries: 3')
$out.Add('  request_timeout: 600')

# Budget controls — emitted when any enabled peer defines a budget field
$budgetPeer = $peers | Where-Object { $_.budget -and $_.budget -gt 0 } | Select-Object -First 1
if ($budgetPeer) {
    $period = if ($budgetPeer.budgetPeriod) { $budgetPeer.budgetPeriod } else { '1d' }
    $out.Add("  max_budget: $($budgetPeer.budget)")
    $out.Add("  budget_duration: `"$period`"")
}

# Langfuse callbacks — enabled via defaults.langfuseEnabled in models.psd1 / user.psd1
if ($cfg.defaults.langfuseEnabled) {
    $langfusePort = $cfg.defaults.langfusePort ?? 3001
    $out.Add('  success_callback: ["langfuse"]')
    $out.Add('  failure_callback: ["langfuse"]')
    $out.Add("  langfuse_host: http://localhost:$langfusePort")
    $out.Add('  # langfuse_public_key and langfuse_secret_key: set as LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY env vars')
} else {
    $out.Add('  # Enable Langfuse tracing: set langfuseEnabled = $true in config/user.psd1, then bob gen + bob litellm')
    $out.Add('  # Set LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY as environment variables (Settings → API Keys in Langfuse UI)')
}
$out.Add('')
$out.Add('general_settings:')
$out.Add('  drop_params: true      # silently drop unsupported params from clients (avoids 400s)')
$out.Add('  master_key: sk-local   # dummy — proxy is local-only, no real auth needed')

$outFile = Join-Path $script:ModelsRepo 'config\litellm.yaml'
($out -join "`n") + "`n" | Set-Content -LiteralPath $outFile -Encoding utf8 -NoNewline
Write-Host "Generated $outFile" -ForegroundColor Green
