#requires -Version 7
# 'llm' — short CLI for the local stack. Put on PATH by scripts/install-cli.ps1.
# Usage:  llm <command> [args]   (run `llm help` for the list)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\_models.ps1"
$base = "http://localhost:8080/v1"
# Copy out of the automatic $args (whose slicing unwraps oddly) into plain arrays.
$argv = @($args)
$cmd  = if ($argv.Count) { $argv[0] } else { 'help' }
$rest = @($argv | Select-Object -Skip 1)   # always an array, even for a single arg

switch ($cmd) {
  'diagnose' { & "$repo\scripts\diagnose.ps1" }
  'up'     { & "$repo\scripts\up.ps1" }                       # endpoint + Open WebUI
  'serve'  { & "$repo\scripts\start.ps1" }                    # endpoint only (:8080)
  'webui'  { & "$repo\tools\venv-webui\Scripts\open-webui.exe" serve --port 3000 }
  'aider'  { & "$repo\tools\venv-aider\Scripts\aider.exe" @rest }   # runs in your current folder
  'models' { (Invoke-RestMethod "$base/models").data.id }
  'gen'    { & "$repo\scripts\gen-llama-swap.ps1" @rest }     # regenerate config from models.psd1
  'fetch'  {                                                  # download models for a profile
    $fa = @{}
    if ($rest -contains '--list') { $fa['ListOnly'] = $true }
    $prof = @($rest | Where-Object { $_ -ne '--list' })
    if ($prof.Count) { $fa['Profile'] = $prof[0] }
    & "$repo\scripts\fetch-models.ps1" @fa
  }
  'profiles' {
    $cfg = Get-ModelsConfig
    foreach ($p in $cfg.profiles.Keys | Sort-Object) {
      $roles = @($cfg.profiles[$p].Keys | Where-Object { -not $_.StartsWith('_') })
      $gb    = ($roles | ForEach-Object { $cfg.profiles[$p][$_].sizeGB } | Measure-Object -Sum).Sum
      $have  = @($roles | Where-Object { Test-Path (Join-Path $repo "models\$($cfg.profiles[$p][$_].gguf)") }).Count
      $mark  = if ($p -eq $cfg.activeProfile) { '* ' } else { '  ' }
      Write-Host ("{0}{1,-6} ~{2,5:N1} GB  {3}/{4} on disk   {5}" -f $mark, $p, $gb, $have, $roles.Count, $cfg.profiles[$p]._targetVRAM)
    }
    $vram = Get-GpuVramGB; $sug = Get-SuggestedProfile -VramGB $vram
    if ($sug) { Write-Host "`nDetected ~$vram GB VRAM -> suggested '$sug'." -ForegroundColor DarkGray }
    Write-Host "(* = active)  switch: llm profile <name>   peek without switching: llm fetch --list <name>" -ForegroundColor DarkGray
  }
  'profile'  {
    if (-not $rest.Count) { Write-Host "usage: llm profile <name>   (see: llm profiles)"; break }
    Set-ActiveProfile $rest[0]
    & "$repo\scripts\gen-llama-swap.ps1"
    & "$repo\scripts\fetch-models.ps1" -ListOnly
    Write-Host "If any model is MISSING above, download it:  llm fetch" -ForegroundColor Yellow
  }
  'bench'  {
    $default = Join-Path $repo "models\$((Get-Models).models | Where-Object role -eq 'coder' | ForEach-Object gguf)"
    $m = if ($rest.Count) { $rest[0] } else { $default }
    & "$repo\bin\llama-bench.exe" -m $m -ngl 99 -fa 1 -p 512 -n 128
  }
  'chat'   {
    if ($rest.Count -lt 2) { Write-Host "usage: llm chat <model> <prompt...>   (models: coder chat planner fim)"; break }
    $model = $rest[0]; $prompt = ($rest[1..($rest.Count-1)] -join ' ')
    $body = @{ model=$model; messages=@(@{role='user';content=$prompt}); max_tokens=512 } | ConvertTo-Json -Depth 6
    try {
      $r = Invoke-RestMethod "$base/chat/completions" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 300
      $r.choices[0].message.content
    } catch { Write-Warning "is the endpoint up? start it with: llm serve   ($_)" }
  }
  'stop'   {
    Get-Process llama-swap,llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
    Write-Host "stopped llama-swap + llama-server (frees VRAM). Close the Open WebUI window to stop it." -ForegroundColor Green
  }
  default  {
@"
llm — local LLM stack (endpoint $base)
  llm diagnose             GPU, VRAM, CUDA, and model file health check
  llm up                   start endpoint :8080 + Open WebUI :3000 (two windows)
  llm serve                start the endpoint only (:8080)
  llm stop                 stop the endpoint (frees VRAM)
  llm aider [args]         aider architect mode in the CURRENT folder
  llm webui                Open WebUI only (:3000)
  llm chat <model> <text>  one-shot chat   e.g.  llm chat coder "write fizzbuzz"
  llm models               list model names (coder chat planner fim embed)
  llm bench [gguf]         throughput benchmark (default: active profile's coder)
  llm profiles             list VRAM profiles + which is active (config/models.psd1)
  llm profile <name>       switch profile (regenerates config; e.g. llm profile 12gb)
  llm fetch [--list] [p]   download models for a profile (--list = dry-run, no download)
  llm gen                  regenerate config/llama-swap.yaml from config/models.psd1
"@
  }
}
