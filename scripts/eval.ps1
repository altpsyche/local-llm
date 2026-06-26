#requires -Version 7
# Benchmark a model role for quality using lm-evaluation-harness.
# Usage: llm eval <role> [task] [--shots N]
# Examples:
#   llm eval coder humaneval      # code generation (HumanEval benchmark)
#   llm eval planner mmlu         # general knowledge (5-shot)
#   llm eval coder gsm8k          # math word problems
#   llm eval planner hellaswag    # common-sense reasoning
# Results are saved as JSON to results/eval-<role>-<task>-<timestamp>/
param(
    [string]$Role  = 'coder',
    [string]$Task  = 'mmlu',
    [int]   $Shots = 0
)
$ErrorActionPreference = "Stop"
$repo   = Split-Path $PSScriptRoot -Parent
$lmEval = Join-Path $repo 'tools\venv-eval\Scripts\lm_eval.exe'

if (-not (Test-Path $lmEval)) {
    throw "lm-eval not installed. Run: .\scripts\bootstrap-eval.ps1"
}

. "$PSScriptRoot\_models.ps1"
$cfg  = Get-ModelsConfig
$port = $cfg.defaults.port ?? 8080

try { Invoke-RestMethod "http://localhost:$port/v1/models" -TimeoutSec 3 | Out-Null }
catch { throw "Endpoint not running at http://localhost:$port/v1 — start it first: llm serve" }

$resultsDir = Join-Path $repo 'results'
if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory $resultsDir | Out-Null }
$outPath = Join-Path $resultsDir "eval-$Role-$Task-$(Get-Date -f yyyyMMdd-HHmm)"

Write-Host "Benchmarking '$Role' on '$Task' (shots=$Shots)..." -ForegroundColor Cyan
Write-Host "Endpoint: http://localhost:$port/v1" -ForegroundColor DarkGray
Write-Host "Results:  $outPath" -ForegroundColor DarkGray
Write-Host ""

& $lmEval `
    --model local-completions `
    --model_args "base_url=http://localhost:$port/v1,model=$Role,tokenized_requests=False" `
    --tasks $Task `
    --apply_chat_template `
    --num_fewshot $Shots `
    --output_path $outPath `
    --log_samples
