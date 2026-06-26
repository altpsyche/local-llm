#requires -Version 7
# ONE-TIME: point VS Code Continue + aider at the repo's config files.
# Tries a symlink (edits in the repo propagate live); falls back to a copy if you lack
# symlink privilege (enable Windows Developer Mode, or run as admin, to get symlinks).
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent

function Wire($target, $link) {
  $dir = Split-Path $link -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  if (Test-Path $link) { Write-Warning "exists, left as-is: $link  (delete it to re-wire)"; return }
  try {
    New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null
    Write-Host "linked  $link  ->  $target" -ForegroundColor Green
  } catch {
    Copy-Item $target $link -Force
    Write-Host "copied  $target  ->  $link   (no symlink priv; re-run after editing the repo config)" -ForegroundColor Yellow
  }
}

# Continue (VS Code / JetBrains): ~/.continue/config.yaml
Wire "$repo\config\continue\config.yaml" "$HOME\.continue\config.yaml"
# aider: ~/.aider.conf.yml  (auto-discovered from home, so no --config flag needed afterwards)
Wire "$repo\config\aider\.aider.conf.yml" "$HOME\.aider.conf.yml"

Write-Host "`nChecking tool installations..."

$codeCmd   = Get-Command code -ErrorAction SilentlyContinue
$installed = if ($codeCmd) { code --list-extensions 2>$null } else { @() }
$continueOk = $installed | Select-String -Quiet 'Continue.continue'
$clineOk    = $installed | Select-String -Quiet 'saoudrizwan.claude-dev'

if ($codeCmd) {
    if ($continueOk) {
        Write-Host "  [OK] Continue extension installed" -ForegroundColor Green
    } else {
        Write-Host "  [!] Continue extension NOT found" -ForegroundColor Yellow
        Write-Host "      Install: code --install-extension Continue.continue"
        Write-Host "      Or:      https://marketplace.visualstudio.com/items?itemName=Continue.continue"
    }
    if ($clineOk) {
        Write-Host "  [OK] Cline extension installed" -ForegroundColor Green
    } else {
        Write-Host "  [-] Cline extension not found (optional)"
        Write-Host "      Install: code --install-extension saoudrizwan.claude-dev"
    }
} else {
    Write-Host "  [-] VS Code (code) not on PATH — skipping extension checks" -ForegroundColor DarkGray
    Write-Host "      Install VS Code and re-run: .\scripts\setup-clients.ps1"
}

$aiderExe = Join-Path $PSScriptRoot '..\tools\venv-aider\Scripts\aider.exe'
if (Test-Path $aiderExe) {
    Write-Host "  [OK] aider installed at tools/venv-aider/" -ForegroundColor Green
} else {
    Write-Host "  [!] aider not found — run setup first: .\setup.bat" -ForegroundColor Yellow
}

Write-Host "`nDone. Open WebUI is auto-wired by scripts\up.ps1 (env vars) — nothing to do here for it." -ForegroundColor Cyan
