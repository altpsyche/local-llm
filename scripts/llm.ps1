#requires -Version 7
# 'llm' — short CLI for the local stack. Put on PATH by scripts/install-cli.ps1.
# Usage:  llm <command> [args]   (run `llm help` for the list)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\_models.ps1"
$d        = (Get-ModelsConfig).defaults
$port     = $d.port ?? 8080
$base     = "http://localhost:$port/v1"
# Copy out of the automatic $args (whose slicing unwraps oddly) into plain arrays.
$argv = @($args)
$cmd  = if ($argv.Count) { $argv[0] } else { 'help' }
$rest = @($argv | Select-Object -Skip 1)   # always an array, even for a single arg

switch ($cmd) {
  'status' {
    try { $apiModels = (Invoke-RestMethod "$base/models" -TimeoutSec 3).data }
    catch {
      Write-Host "Endpoint not running. Start with: llm serve" -ForegroundColor Yellow; break
    }
    $loadedIds = @{}; foreach ($m in $apiModels) { $loadedIds[$m.id] = $true }
    $cfg     = Get-ModelsConfig
    $profile = Resolve-ProfileName -Config $cfg
    $models  = (Get-Models -Profile $profile).models
    Write-Host "`nEndpoint: $base  " -NoNewline; Write-Host "[running]" -ForegroundColor Green
    Write-Host "Profile:  $profile`n"
    Write-Host ("{0,-10} {1,-36} {2,-9} {3}" -f 'Role','Model','VRAM','State')
    Write-Host ('-' * 70)
    foreach ($m in $models) {
      $label  = "$($m.gguf -replace '\.gguf$') ($($m.sizeGB) GB)"
      $loaded = $loadedIds.ContainsKey($m.role)
      $state  = if ($m.pinned -and $loaded) { 'loaded (pinned)' }
                elseif ($m.pinned)           { 'loading...' }
                elseif ($loaded)             { 'loaded' }
                else                         { 'unloaded' }
      $color  = if ($loaded) { 'Green' } else { 'DarkGray' }
      $vram   = if ($loaded) { "$($m.sizeGB) GB" } else { '--' }
      Write-Host ("{0,-10} {1,-36} {2,-9} " -f $m.role, $label, $vram) -NoNewline
      Write-Host $state -ForegroundColor $color
    }
    Write-Host ""
  }
  'ps' {
    Write-Host "`nLocal LLM Processes`n"
    Write-Host ("{0,-15} {1,-8} {2,-10} {3,-10} {4}" -f 'Service','PID','RAM','Uptime','Status')
    Write-Host ('-' * 60)
    foreach ($svc in @('llama-swap','open-webui')) {
      $pf = Join-Path $repo "logs\$svc.pid"
      if (Test-Path $pf) {
        $wPid = [int](Get-Content $pf -Raw)
        $proc = Get-Process -Id $wPid -ErrorAction SilentlyContinue
        if ($proc) {
          $ram    = "$([math]::Round($proc.WorkingSet64/1MB)) MB"
          $uptime = ([DateTime]::Now - $proc.StartTime).ToString('hh\:mm\:ss')
          Write-Host ("{0,-15} {1,-8} {2,-10} {3,-10} " -f $svc,$wPid,$ram,$uptime) -NoNewline
          Write-Host "running" -ForegroundColor Green
        } else {
          Write-Host ("{0,-15} {1,-8} {2,-10} {3,-10} " -f $svc,$wPid,'--','--') -NoNewline
          Write-Host "dead (stale PID file)" -ForegroundColor Red
        }
      } else {
        Write-Host ("{0,-15} {1,-8} {2,-10} {3,-10} " -f $svc,'--','--','--') -NoNewline
        Write-Host "not running" -ForegroundColor DarkGray
      }
    }
    Write-Host ""
  }
  'diagnose' { & "$repo\scripts\diagnose.ps1" }
  'up'     { & "$repo\scripts\up.ps1" -NoOpen:($rest -contains '-NoOpen') -WithServices:($rest -contains '-WithServices') }
  'serve'  { & "$repo\scripts\start.ps1" }                    # endpoint only (:8080), interactive
  'restart' {
    Write-Host "Stopping endpoint..."
    Get-Process -Name 'llama-swap','llama-server','open-webui' -ErrorAction SilentlyContinue | Stop-Process -Force
    foreach ($svc in 'llama-swap','open-webui') {
      $pf = Join-Path $repo "logs\$svc.pid"
      if (Test-Path $pf) {
        $wPid = [int](Get-Content $pf -Raw)
        Get-Process -Id $wPid -ErrorAction SilentlyContinue | Stop-Process -Force
        Remove-Item $pf
      }
    }
    Start-Sleep -Milliseconds 500
    Write-Host "Starting endpoint (interactive — Ctrl+C to stop)..."
    & "$repo\scripts\start.ps1"
  }
  'logs' {
    $n = if ($rest.Count -and $rest[0] -match '^\d+$') { [int]$rest[0] } else { 50 }
    $logFile = Join-Path $repo 'logs\llama-swap.log'
    if (-not (Test-Path $logFile)) {
      Write-Host "No log file yet. Start endpoint first: llm serve"; break
    }
    Write-Host "Tailing $logFile (last $n lines, Ctrl+C to stop):`n"
    Get-Content $logFile -Wait -Tail $n
  }
  'webui'  { & "$repo\tools\venv-webui\Scripts\open-webui.exe" serve --port ($d.webuiPort ?? 3000) }
  'aider'  { & "$repo\tools\venv-aider\Scripts\aider.exe" @rest }   # runs in your current folder
  'models' {
    $loadedIds = @{}; $endpointUp = $false
    try {
      $apiModels = (Invoke-RestMethod "$base/models" -TimeoutSec 3).data
      foreach ($m in $apiModels) { $loadedIds[$m.id] = $true }
      $endpointUp = $true
    } catch {}
    $cfg     = Get-ModelsConfig
    $profile = Resolve-ProfileName -Config $cfg
    $models  = (Get-Models -Profile $profile).models
    Write-Host "`nProfile: $profile`n"
    $fmt = "{0,-10} {1,-42} {2,-9} {3}"
    Write-Host ($fmt -f 'Role','Model','VRAM','State'); Write-Host ('-' * 70)
    foreach ($m in $models) {
      $label = "$($m.gguf -replace '\.gguf$','' -replace '[-_]',' ') ($($m.sizeGB) GB)"
      $state = if (-not $endpointUp)        { '(endpoint down)' }
               elseif ($loadedIds[$m.role]) { if ($m.pinned) { 'loaded, pinned' } else { 'loaded' } }
               else                         { 'unloaded' }
      $color = if ($endpointUp -and $loadedIds[$m.role]) { 'Green' } else { 'DarkGray' }
      Write-Host ($fmt -f $m.role, $label, "$($m.sizeGB) GB", '') -NoNewline
      Write-Host $state -ForegroundColor $color
    }
    Write-Host ""
    if (-not $endpointUp) { Write-Host "Endpoint not running — state unknown. llm serve" -ForegroundColor Yellow }
  }
  'show' {
    if (-not $rest.Count) { Write-Host "usage: llm show <role>   (roles: coder chat planner fim embed)"; break }
    $info = Get-Models
    $m = $info.models | Where-Object role -eq $rest[0]
    if (-not $m) { Write-Host "Unknown role '$($rest[0])'. Valid: $($info.models.role -join ', ')"; break }
    $dest = Join-Path $repo "models\$($m.gguf)"
    Write-Host "`nRole:     $($m.role)"
    Write-Host "File:     $($m.gguf)"
    Write-Host "VRAM:     $($m.sizeGB) GB"
    Write-Host "Repo:     $($m.repo)"
    Write-Host "Path:     $($m.path)"
    if (Test-Path $dest) {
      $actGB = [math]::Round((Get-Item $dest).Length/1GB, 2)
      Write-Host "On disk:  $actGB GB" -ForegroundColor Green
    } else {
      Write-Host "On disk:  MISSING" -ForegroundColor Yellow
    }
    $mf = Join-Path $repo 'models\manifest.json'
    if (Test-Path $mf) {
      $manifest = Get-Content $mf -Raw | ConvertFrom-Json -AsHashtable
      if ($manifest[$m.gguf]) {
        $entry = $manifest[$m.gguf]
        Write-Host "SHA256:   $($entry.sha256.Substring(0,24))..."
        Write-Host "Verified: $($entry.verifiedAt)"
      }
    }
    Write-Host ""
  }
  'gen'    { & "$repo\scripts\gen-llama-swap.ps1" @rest }     # regenerate config from models.psd1
  'fetch'  {                                                   # download models for a profile
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
  'profile' {
    if ($rest[0] -eq 'auto' -or -not $rest.Count) {
      $vramGB = Get-GpuVramGB
      if (-not $vramGB) { Write-Host "Cannot detect GPU VRAM. Use: llm profile <name>"; break }
      $sug = Get-SuggestedProfile -VramGB $vramGB
      if (-not $sug) {
        Write-Host "No profile fits $vramGB GB VRAM. Available:"
        (Get-ModelsConfig).profiles.Keys | Sort-Object | ForEach-Object { Write-Host "  $_" }
        break
      }
      Write-Host "Detected $vramGB GB VRAM -> switching to profile: $sug"
      Set-ActiveProfile $sug
      & "$repo\scripts\gen-llama-swap.ps1"
      & "$repo\scripts\fetch-models.ps1" -ListOnly
      Write-Host "If any model is MISSING above, download it:  llm fetch" -ForegroundColor Yellow
    } else {
      Set-ActiveProfile $rest[0]
      & "$repo\scripts\gen-llama-swap.ps1"
      & "$repo\scripts\fetch-models.ps1" -ListOnly
      Write-Host "If any model is MISSING above, download it:  llm fetch" -ForegroundColor Yellow
    }
  }
  'bench'  {
    $allModels = Get-Models
    $resolveModel = {
      param($name)
      $byRole = $allModels.models | Where-Object role -eq $name
      if ($byRole) { Join-Path $repo "models\$($byRole.gguf)" } else { $name }
    }
    $default = & $resolveModel 'coder'
    $m = if ($rest.Count) { & $resolveModel $rest[0] } else { $default }
    & "$repo\bin\llama-bench.exe" -m $m -ngl 99 -fa 1 -p 512 -n 128
  }
  'chat' {
    if ($rest.Count -lt 2) {
      Write-Host "usage: llm chat <model> <prompt...> [--sys <text>] [--max <N>]"
      Write-Host "       llm chat coder 'write fizzbuzz in python'"; break
    }
    $model   = $rest[0]
    $argList = @($rest | Select-Object -Skip 1)
    $maxTok  = $d.maxTokens ?? 512
    $sysPrompt = $null; $promptParts = @(); $i = 0
    while ($i -lt $argList.Count) {
      if ($argList[$i] -eq '--sys' -and $i+1 -lt $argList.Count) {
        $sysPrompt = $argList[$i+1]; $i += 2
      } elseif ($argList[$i] -eq '--max' -and $i+1 -lt $argList.Count) {
        $maxTok = [int]$argList[$i+1]; $i += 2
      } else { $promptParts += $argList[$i]; $i++ }
    }
    $prompt   = $promptParts -join ' '
    $messages = @()
    if ($sysPrompt) { $messages += @{ role='system'; content=$sysPrompt } }
    $messages += @{ role='user'; content=$prompt }
    $body = @{ model=$model; stream=$true; max_tokens=$maxTok; messages=$messages } |
            ConvertTo-Json -Depth 5 -Compress
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
      throw "curl.exe not found (requires Windows 10 1803+). Check: where.exe curl.exe"
    }
    $spinRs = $null; $spinPs = $null
    try {
      $spinRs = [runspacefactory]::CreateRunspace(); $spinRs.Open()
      $spinPs = [powershell]::Create(); $spinPs.Runspace = $spinRs
      $spinPs.AddScript({
          $spin = [char[]]@('|','/','-','\'); $i = 0
          while ($true) { [Console]::Write("`r  $($spin[$i++ % 4]) Generating..."); [System.Threading.Thread]::Sleep(120) }
      }) | Out-Null
      $spinPs.BeginInvoke() | Out-Null
      $script:chatSpinDone = $false

      curl.exe --no-buffer --silent -X POST "$base/chat/completions" `
          -H 'Content-Type: application/json' -d $body |
      ForEach-Object {
        if ($_ -match '^data: (.+)$') {
          $data = $Matches[1]
          if ($data -ne '[DONE]') {
            try {
              $t = ($data | ConvertFrom-Json).choices[0].delta.content
              if ($t) {
                if (-not $script:chatSpinDone) {
                    $spinPs.Stop(); $spinRs.Close()
                    [Console]::Write("`r                    `r")
                    $script:chatSpinDone = $true
                }
                Write-Host -NoNewline $t
              }
            } catch {}
          }
        }
      }
      Write-Host ""
    } catch {
      Write-Host "Chat failed: $_" -ForegroundColor Red
      Write-Host "Is endpoint up? llm serve"
    } finally {
      if (-not $script:chatSpinDone -and $spinPs) {
          $spinPs.Stop()
          if ($spinRs) { $spinRs.Close() }
          [Console]::Write("`r                    `r")
      }
    }
  }
  'stop' {
    Get-Process llama-swap,llama-server,open-webui -ErrorAction SilentlyContinue | Stop-Process -Force
    foreach ($svc in 'llama-swap','open-webui') {
      $pf = Join-Path $repo "logs\$svc.pid"
      if (Test-Path $pf) {
        $wPid = [int](Get-Content $pf -Raw)
        Get-Process -Id $wPid -ErrorAction SilentlyContinue | Stop-Process -Force
        Remove-Item $pf
      }
    }
    Write-Host "Stopped endpoint + services (VRAM freed)." -ForegroundColor Green
  }
  'update' {
    $llmCppPath = Join-Path $repo 'external\llama.cpp'
    $before = git -C $llmCppPath rev-parse --short HEAD 2>$null
    Write-Host "llama.cpp current: $before"
    Write-Host "Pulling latest via submodule update..."
    git -C $repo submodule update --remote -- external/llama.cpp
    if ($LASTEXITCODE -ne 0) { Write-Host "submodule update failed." -ForegroundColor Red; break }
    $after = git -C $llmCppPath rev-parse --short HEAD 2>$null
    if ($before -eq $after) { Write-Host "Already up to date ($after). No rebuild needed."; break }
    Write-Host "Updated: $before -> $after"
    Write-Host "Rebuilding..."
    & "$repo\scripts\build-llama.ps1" -Force
    if ($LASTEXITCODE -ne 0) { Write-Host "Build failed." -ForegroundColor Red; break }
    Write-Host "Benchmarking..."
    & "$repo\scripts\llm.ps1" bench
  }
  'version' {
    $swapVer    = & "$repo\bin\llama-swap.exe"   --version 2>&1 | Select-Object -First 1
    $srvVer     = & "$repo\bin\llama-server.exe" --version 2>&1 | Select-Object -First 1
    $swapCommit = git -C "$repo\external\llama-swap" rev-parse --short HEAD 2>$null
    $llmCommit  = git -C "$repo\external\llama.cpp"  rev-parse --short HEAD 2>$null
    Write-Host "llama-swap:   $swapVer  ($swapCommit)"
    Write-Host "llama-server: $srvVer  ($llmCommit)"
  }
  'verify-urls' {
    $vArgs = @{}
    if ($rest.Count) { $vArgs['Profile'] = $rest[0] }
    & "$repo\scripts\verify-urls.ps1" @vArgs
  }
  'mlock' {
    # Check current status first (no admin needed)
    $mlockStatus = & "$repo\scripts\grant-mlock.ps1" -Check 2>&1
    Write-Host $mlockStatus
    if ($LASTEXITCODE -ne 0) {
      Write-Host ""
      Write-Host "This grants the Windows SeLockMemoryPrivilege to your user account." -ForegroundColor DarkGray
      Write-Host "Required for --mlock to actually pin model weights in RAM." -ForegroundColor DarkGray
      Write-Host "A UAC prompt will appear. After granting, restart this terminal." -ForegroundColor DarkGray
      Write-Host ""
      $ans = Read-Host "Grant now? [y/N]"
      if ($ans -match '^[Yy]') {
        & "$repo\scripts\grant-mlock.ps1"
      }
    }
  }
  'fabric-setup' { & "$repo\scripts\setup-fabric.ps1" }
  'fabric'       { & "$repo\bin\fabric.exe" @rest }
  'litellm' {
    $subCmd  = if ($rest.Count -and $rest[0] -in 'stop','status','start') { $rest[0] } else { '' }
    $fwdArgs = if ($subCmd) { @($rest | Select-Object -Skip 1) } else { @($rest) }
    $pidFile = Join-Path $repo 'logs\litellm.pid'
    $lPort   = $d.litellmPort ?? 8081
    switch ($subCmd) {
      'stop' {
        if (Test-Path $pidFile) {
          $wPid = [int](Get-Content $pidFile -Raw)
          Get-Process -Id $wPid -ErrorAction SilentlyContinue | Stop-Process -Force
          Remove-Item $pidFile -ErrorAction SilentlyContinue
          Write-Host "LiteLLM stopped." -ForegroundColor Green
        } else { Write-Host "LiteLLM not running." -ForegroundColor DarkGray }
      }
      'status' {
        if (Test-Path $pidFile) {
          $wPid = [int](Get-Content $pidFile -Raw)
          $proc = Get-Process -Id $wPid -ErrorAction SilentlyContinue
          if ($proc) {
            $uptime = ([DateTime]::Now - $proc.StartTime).ToString('hh\:mm\:ss')
            Write-Host "LiteLLM running  PID=$wPid  uptime=$uptime  http://localhost:$lPort/v1" -ForegroundColor Green
          } else { Write-Host "LiteLLM dead (stale PID $wPid)." -ForegroundColor Red }
        } else { Write-Host "LiteLLM not running." -ForegroundColor DarkGray }
      }
      default { & "$repo\scripts\start-litellm.ps1" @fwdArgs }
    }
  }
  'services' {
    $action  = if ($rest.Count) { $rest[0] } else { '' }
    $compose = "$repo\tools\compose\docker-compose.yml"
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
      Write-Host "Docker not found. Run: .\scripts\setup-docker.ps1" -ForegroundColor Yellow; break
    }
    $envFile = "$repo\tools\compose\.env"
    switch ($action) {
      'start'  {
        # Regenerate .env from current models.psd1 values before starting
        $dp = (Get-ModelsConfig).defaults
        @"
REPO_PATH=$repo
LANGFUSE_PORT=$($dp.langfusePort ?? 3001)
SEARXNG_PORT=$($dp.searxngPort ?? 8888)
N8N_PORT=$($dp.n8nPort ?? 5678)
"@ | Set-Content $envFile -Encoding utf8
        docker compose -f $compose up -d
        Write-Host "Services started:" -ForegroundColor Green
        docker compose -f $compose ps --format json 2>$null | ConvertFrom-Json | ForEach-Object {
            $state = if ($_.Health) { $_.Health } else { $_.State }
            $color = if ($state -eq 'healthy') { 'Green' } else { 'DarkGray' }
            Write-Host ("  {0,-40} {1}" -f $_.Name, $state) -ForegroundColor $color
        }
      }
      'stop'   { docker compose -f $compose down }
      'status' { docker compose -f $compose ps }
      'logs'   { docker compose -f $compose logs --tail=50 -f }
      default  { Write-Host "Usage: llm services start|stop|status|logs" }
    }
  }
  'eval' {
    $eArgs = @{}
    $pos = @()
    for ($i = 0; $i -lt $rest.Count; $i++) {
      if ($rest[$i] -eq '--shots' -and $i+1 -lt $rest.Count) { $eArgs['Shots'] = [int]$rest[++$i] }
      elseif ($rest[$i] -eq '--limit' -and $i+1 -lt $rest.Count) { $eArgs['Limit'] = [int]$rest[++$i] }
      else { $pos += $rest[$i] }
    }
    if ($pos.Count -ge 1) { $eArgs['Role'] = $pos[0] }
    if ($pos.Count -ge 2) { $eArgs['Task'] = $pos[1] }
    & "$repo\scripts\eval.ps1" @eArgs
  }
  default {
    $wp = $d.webuiPort ?? 3000
@"
llm — local LLM stack (endpoint $base)

Inference:
  llm serve                            Start API endpoint (:$port) — interactive, Ctrl+C to stop
  llm up [-NoOpen]                     Start endpoint + Open WebUI silently [+ browser]
  llm stop                             Stop all services (frees VRAM)
  llm restart                          Stop then start endpoint (interactive)
  llm status                           Loaded models and VRAM usage
  llm ps                               Daemon processes with PID, RAM, uptime
  llm logs [-n N]                      Tail server log (default: last 50 lines)

Models:
  llm models                           List models with backing names and state
  llm show <role>                      Model info: file, VRAM, SHA256, disk status
  llm chat <model> <prompt>            Streaming chat
    [--sys <system>] [--max <tokens>]
  llm bench [gguf]                     Throughput benchmark

Management:
  llm profiles                         List VRAM profiles with sizes and active marker
  llm profile <name|auto>              Switch profile (auto = detect from GPU VRAM)
  llm fetch [--list] [profile]         Download models for active/specified profile
  llm verify-urls [<profile>]          Check HuggingFace download URLs
  llm update                           Pull latest llama.cpp and rebuild
  llm gen                              Regenerate config/llama-swap.yaml

Tools:
  llm aider [args]                     Start aider in current folder
  llm webui                            Launch Open WebUI only (:$wp)
  llm diagnose                         System and model health check
  llm mlock                            Check/grant SeLockMemoryPrivilege (needed for --mlock)
  llm version                          Show binary versions and submodule commits

Ecosystem:
  llm fabric-setup                     Install fabric and configure it for the local endpoint
  llm litellm [start]                  Start LiteLLM proxy (:8081) — API gateway + retry layer
  llm litellm stop                     Stop LiteLLM proxy
  llm litellm status                   Check if LiteLLM proxy is running
  llm services start|stop|status|logs  Docker services: Langfuse (:3001) SearXNG (:8888) n8n (:5678)
  llm eval <role> [task]               Benchmark model quality (mmlu, humaneval, gsm8k)
"@
  }
}
