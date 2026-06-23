#requires -Version 7
# 'llm' — short CLI for the local stack. Put on PATH by scripts/install-cli.ps1.
# Usage:  llm <command> [args]   (run `llm help` for the list)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$base = "http://localhost:8080/v1"
$cmd  = if ($args.Count) { $args[0] } else { 'help' }
$rest = if ($args.Count -gt 1) { $args[1..($args.Count-1)] } else { @() }

switch ($cmd) {
  'up'     { & "$repo\scripts\up.ps1" }                       # endpoint + Open WebUI
  'serve'  { & "$repo\scripts\start.ps1" }                    # endpoint only (:8080)
  'webui'  { & "$repo\tools\venv-webui\Scripts\open-webui.exe" serve --port 3000 }
  'aider'  { & "$repo\tools\venv-aider\Scripts\aider.exe" @rest }   # runs in your current folder
  'models' { (Invoke-RestMethod "$base/models").data.id }
  'bench'  {
    $m = if ($rest.Count) { $rest[0] } else { "$repo\models\qwen-coder-14b-q4_k_m.gguf" }
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
  llm up                   start endpoint :8080 + Open WebUI :3000 (two windows)
  llm serve                start the endpoint only (:8080)
  llm stop                 stop the endpoint (frees VRAM)
  llm aider [args]         aider architect mode in the CURRENT folder
  llm webui                Open WebUI only (:3000)
  llm chat <model> <text>  one-shot chat   e.g.  llm chat coder "write fizzbuzz"
  llm models               list model names (coder chat planner fim embed)
  llm bench [gguf]         throughput benchmark (default: coder 14B)
"@
  }
}
