#requires -Version 7
# Install the 'llm' command on PATH (a .cmd shim in scoop\shims pointing at scripts/llm.ps1).
# Works from any shell (cmd or PowerShell). Idempotent.
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$llm  = Join-Path $repo "scripts\llm.ps1"
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source

# locate a PATH dir to drop the shim into (prefer scoop\shims)
$shimDir = $null
$sc = Get-Command scoop -ErrorAction SilentlyContinue
if ($sc -and $sc.Source) { $shimDir = Split-Path $sc.Source }
if (-not $shimDir -or -not (Test-Path $shimDir)) { $shimDir = Join-Path $HOME "scoop\shims" }
if (-not (Test-Path $shimDir)) { throw "No scoop\shims dir found at $shimDir. Add scripts\ to PATH manually instead." }

$cmdPath = Join-Path $shimDir "llm.cmd"
@"
@echo off
"$pwsh" -NoProfile -ExecutionPolicy Bypass -File "$llm" %*
"@ | Set-Content -Path $cmdPath -Encoding ascii

Write-Host "'llm' installed -> $cmdPath" -ForegroundColor Green

# Register tab completions in the user's PowerShell profile (idempotent)
$profilePath  = $PROFILE.CurrentUserAllHosts
$modelsFile   = Join-Path $repo 'config\models.psd1'
if (-not (Test-Path $profilePath)) { New-Item -Path $profilePath -Force | Out-Null }

$completerBlock = @"

# llm CLI tab completions (added by local-llm install-cli.ps1)
Register-ArgumentCompleter -Native -CommandName llm -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    `$tokens = @(`$commandAst.CommandElements | Select-Object -Skip 1 | ForEach-Object { "`$_" })
    `$cmd = if (`$tokens.Count -gt 0) { `$tokens[0] } else { '' }
    `$subCmds = @('serve','up','stop','restart','status','logs','models','chat','bench',
                 'profiles','profile','fetch','verify-urls','update','gen','aider','webui',
                 'diagnose','ps','show','version')
    if (`$tokens.Count -le 1) {
        `$subCmds | Where-Object { `$_ -like "`$wordToComplete*" } |
            ForEach-Object { [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_) }
    } elseif (`$cmd -in @('chat','bench','show')) {
        @('planner','coder','chat','fim','embed') | Where-Object { `$_ -like "`$wordToComplete*" } |
            ForEach-Object { [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_) }
    } elseif (`$cmd -eq 'profile') {
        `$profiles = @('auto')
        if (Test-Path '$modelsFile') {
            `$profiles += (Import-PowerShellDataFile '$modelsFile').profiles.Keys | Sort-Object
        }
        `$profiles | Where-Object { `$_ -like "`$wordToComplete*" } |
            ForEach-Object { [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_) }
    } elseif (`$cmd -eq 'fetch') {
        @('--list') | Where-Object { `$_ -like "`$wordToComplete*" } |
            ForEach-Object { [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_) }
    } elseif (`$cmd -eq 'up') {
        @('-NoOpen') | Where-Object { `$_ -like "`$wordToComplete*" } |
            ForEach-Object { [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_) }
    }
}
"@

$existing = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
if (-not $existing -or -not $existing.Contains('llm CLI tab completions')) {
    Add-Content -Path $profilePath -Value $completerBlock -Encoding utf8
    Write-Host "Tab completions added to: $profilePath" -ForegroundColor Green
    Write-Host "(Restart terminal or: . `$PROFILE)" -ForegroundColor DarkGray
} else {
    Write-Host "Tab completions already registered." -ForegroundColor DarkGray
}

Write-Host "Open a NEW terminal, then try:  llm help" -ForegroundColor Cyan
