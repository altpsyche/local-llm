#requires -Version 7
# Build the llama-swap submodule (Go) into bin/.
# Fallback if you don't want Go: download the matching native Windows binary from
#   https://github.com/mostlygeek/llama-swap/releases  into  bin\llama-swap.exe
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$src  = Join-Path $repo "external\llama-swap"
$bin  = Join-Path $repo "bin"

if (-not (Test-Path $src)) {
  throw "llama-swap submodule not found at $src. Run: git submodule update --init --recursive"
}
if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
  throw "Go not found. Either 'scoop install go', or download the llama-swap release binary into $bin\llama-swap.exe"
}

New-Item -ItemType Directory -Force -Path $bin | Out-Null
Push-Location $src
try {
  go build -o (Join-Path $bin "llama-swap.exe") .
  if ($LASTEXITCODE -ne 0) { throw "go build failed" }
} finally { Pop-Location }
Write-Host "Built: $bin\llama-swap.exe" -ForegroundColor Green
