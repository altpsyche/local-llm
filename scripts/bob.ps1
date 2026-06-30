#requires -Version 7
# 'bob' — personal AI assistant CLI. Put on PATH by scripts/install-cli.ps1.
# Usage:  bob <command> [args]   (run `bob help` for the list)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\_models.ps1"
$d        = (Get-ModelsConfig).defaults
$port        = $d.port ?? 8080
$litellmPort = $d.litellmPort ?? 8081
$base        = "http://localhost:$port/v1"
$litellmBase = "http://localhost:$litellmPort/v1"
# Copy out of the automatic $args (whose slicing unwraps oddly) into plain arrays.
$argv = @($args)
$cmd  = if ($argv.Count) { $argv[0] } else { 'help' }
$rest = @($argv | Select-Object -Skip 1)   # always an array, even for a single arg

function Invoke-BobStream {
  # Stream a chat completion to stdout. Returns the full assistant text.
  # -Raw: suppress spinner + ANSI output, return clean text only (used by bob voice).
  param(
    [string]$Model,
    [object[]]$Messages,
    [int]$MaxTokens = 512,
    [string]$ApiBase,
    [switch]$Raw
  )
  if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    throw "curl.exe not found (requires Windows 10 1803+)"
  }
  $body = @{ model=$Model; stream=$true; max_tokens=$MaxTokens; messages=$Messages } |
          ConvertTo-Json -Depth 8 -Compress
  # Write body to a temp file — avoids Windows 32 KB command-line limit for large payloads (e.g. base64 images).
  # Use UTF-8 without BOM — BOM breaks JSON parsers (litellm, llama-server).
  $bodyTmp = [IO.Path]::GetTempFileName()
  [IO.File]::WriteAllText($bodyTmp, $body, [System.Text.UTF8Encoding]::new($false))
  $full = [System.Text.StringBuilder]::new()
  $spinRs = $null; $spinPs = $null; $spinDone = $false
  try {
    if (-not $Raw) {
      $spinRs = [runspacefactory]::CreateRunspace(); $spinRs.Open()
      $spinPs = [powershell]::Create(); $spinPs.Runspace = $spinRs
      $spinPs.AddScript({
        $spin = [char[]]@('|','/','-','\'); $i = 0
        while ($true) { [Console]::Write("`r  $($spin[$i++ % 4]) ..."); [System.Threading.Thread]::Sleep(120) }
      }) | Out-Null
      $spinPs.BeginInvoke() | Out-Null
    }

    curl.exe --no-buffer --silent -X POST "$ApiBase/chat/completions" `
        -H 'Content-Type: application/json' `
        -H 'Authorization: Bearer sk-local' `
        -d "@$bodyTmp" |
    ForEach-Object {
      if ($_ -match '^data: (.+)$') {
        $chunk = $Matches[1]
        if ($chunk -ne '[DONE]') {
          try {
            $t = ($chunk | ConvertFrom-Json).choices[0].delta.content
            if ($t) {
              if (-not $Raw -and -not $spinDone) {
                $spinPs.Stop(); $spinRs.Close()
                [Console]::Write("`r           `r")
                $spinDone = $true
              }
              if (-not $Raw) { Write-Host -NoNewline $t }
              [void]$full.Append($t)
            }
          } catch {}
        }
      }
    }
  } catch {
    Write-Host "Chat failed: $_" -ForegroundColor Red
    Write-Host "Is endpoint up? bob serve"
  } finally {
    if (-not $Raw -and -not $spinDone -and $spinPs) {
      $spinPs.Stop()
      if ($spinRs) { $spinRs.Close() }
      [Console]::Write("`r           `r")
    }
    Remove-Item $bodyTmp -ErrorAction SilentlyContinue
  }
  return $full.ToString()
}

function Format-ForSpeech {
  # Strip markdown formatting before passing text to a TTS engine.
  # System prompts are advisory — this is the reliable safety net.
  param([string]$Text)
  $t = $Text
  $t = [regex]::Replace($t, '```[a-zA-Z]*\r?\n?', '')   # fenced code blocks — strip fence
  $t = $t.Replace('```', '')
  $t = [regex]::Replace($t, '`([^`]+)`', '$1')           # inline code
  $t = [regex]::Replace($t, '\*\*([^*]+)\*\*', '$1')     # **bold**
  $t = [regex]::Replace($t, '\*([^*\n]+)\*', '$1')       # *italic*
  $t = [regex]::Replace($t, '__([^_]+)__', '$1')         # __bold__
  $t = [regex]::Replace($t, '_([^_\n]+)_', '$1')         # _italic_
  $t = [regex]::Replace($t, '(?m)^#{1,6}\s+', '')        # headings
  $t = [regex]::Replace($t, '(?m)^[ \t]*[-*+]\s+', '')   # unordered bullets
  $t = [regex]::Replace($t, '(?m)^[ \t]*\d+\.\s+', '')   # numbered lists (keep the text)
  $t = [regex]::Replace($t, '(?m)^[-*_]{3,}\s*$', '')    # horizontal rules
  $t = [regex]::Replace($t, '\[([^\]]+)\]\([^\)]+\)', '$1')  # [link text](url)
  $t = [regex]::Replace($t, '(?m)^>\s?', '')             # blockquotes
  $t = $t.Replace('|', ' ')                              # table pipes → space
  $t = [regex]::Replace($t, '[ \t]{2,}', ' ')            # collapse multiple spaces
  $t = [regex]::Replace($t, '(\r?\n){3,}', "`n`n")       # collapse excess blank lines
  return $t.Trim()
}


switch ($cmd) {
  'status' {
    try { $apiModels = (Invoke-RestMethod "$base/models" -TimeoutSec 3).data }
    catch {
      Write-Host "Endpoint not running. Start with: bob serve" -ForegroundColor Yellow; break
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
    $bobVoice = try { (Get-BobConfig).voice } catch { $null }
    $sttPort  = $bobVoice.sttPort ?? 8082
    try {
      $tcp = [Net.Sockets.TcpClient]::new('127.0.0.1', $sttPort); $tcp.Close()
      Write-Host ("  {0,-10} {1,-36} {2}" -f 'whisper','(stt server)',"UP (port $sttPort)") -ForegroundColor Green
    } catch {
      Write-Host ("  {0,-10} {1,-36} {2}" -f 'whisper','(stt server)',"down (port $sttPort)") -ForegroundColor DarkGray
    }
    $ttsPort = $bobVoice.ttsPort ?? 8083
    try {
      $tcp = [Net.Sockets.TcpClient]::new('127.0.0.1', $ttsPort); $tcp.Close()
      Write-Host ("  {0,-10} {1,-36} {2}" -f 'piper','(tts server)',"UP (port $ttsPort)") -ForegroundColor Green
    } catch {
      Write-Host ("  {0,-10} {1,-36} {2}" -f 'piper','(tts server)',"down (port $ttsPort)") -ForegroundColor DarkGray
    }
    Write-Host ""
  }
  'ps' {
    Write-Host "`nBob Processes`n"
    Write-Host ("{0,-15} {1,-8} {2,-10} {3,-10} {4}" -f 'Service','PID','RAM','Uptime','Status')
    Write-Host ('-' * 60)
    foreach ($svc in @('llama-swap','litellm','open-webui','whisper','piper')) {
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
  'serve'  { & "$repo\scripts\start.ps1" }                    # llama-swap (:8080) + LiteLLM (:8081), interactive
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
    $litellmPid = Join-Path $repo 'logs\litellm.pid'
    if (Test-Path $litellmPid) {
      $wPid = [int](Get-Content $litellmPid -Raw -ErrorAction SilentlyContinue)
      if ($wPid) { Get-Process -Id $wPid -ErrorAction SilentlyContinue | Stop-Process -Force }
      Remove-Item $litellmPid -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 500
    Write-Host "Starting endpoint (interactive — Ctrl+C to stop)..."
    & "$repo\scripts\start.ps1"
  }
  'logs' {
    $n = if ($rest.Count -and $rest[0] -match '^\d+$') { [int]$rest[0] } else { 50 }
    $logFile = Join-Path $repo 'logs\llama-swap.log'
    if (-not (Test-Path $logFile)) {
      Write-Host "No log file yet. Start endpoint first: bob serve"; break
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
    if (-not $endpointUp) { Write-Host "Endpoint not running — state unknown. bob serve" -ForegroundColor Yellow }
  }
  'show' {
    if (-not $rest.Count) { Write-Host "usage: bob show <role>   (roles: coder chat planner fim embed)"; break }
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
  'gen'    {                                                   # regenerate config from models.psd1
    & "$repo\scripts\gen-llama-swap.ps1" @rest
    & "$repo\scripts\gen-litellm.ps1"
    & "$repo\scripts\gen-webui.ps1"
  }
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
    Write-Host "(* = active)  switch: bob profile <name>   peek without switching: bob fetch --list <name>" -ForegroundColor DarkGray
  }
  'profile' {
    if ($rest[0] -eq 'auto' -or -not $rest.Count) {
      $vramGB = Get-GpuVramGB
      if (-not $vramGB) { Write-Host "Cannot detect GPU VRAM. Use: bob profile <name>"; break }
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
      Write-Host "If any model is MISSING above, download it:  bob fetch" -ForegroundColor Yellow
    } else {
      Set-ActiveProfile $rest[0]
      & "$repo\scripts\gen-llama-swap.ps1"
      & "$repo\scripts\fetch-models.ps1" -ListOnly
      Write-Host "If any model is MISSING above, download it:  bob fetch" -ForegroundColor Yellow
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
    # --- Flag extraction ---
    $isPro    = $rest -contains '--pro'
    $isThink  = $rest -contains '--think'
    $isCode   = $rest -contains '--code'
    $isRaw    = $rest -contains '--raw'
    $maxTok   = $d.maxTokens ?? 512
    # Strip known flags; --max N is handled below
    $restWork = [System.Collections.Generic.List[string]]($rest | Where-Object { $_ -notin '--pro','--think','--code','--raw' })
    for ($fi = 0; $fi -lt $restWork.Count; $fi++) {
      if ($restWork[$fi] -eq '--max' -and $fi+1 -lt $restWork.Count) {
        $maxTok = [int]$restWork[$fi+1]; $restWork.RemoveAt($fi+1); $restWork.RemoveAt($fi); break
      }
    }
    $restClean = $restWork.ToArray()

    # --- Legacy syntax: bob chat <knownRole> <prompt...> [--sys <text>] ---
    $knownRoles = @('chat','coder','planner','fim','embed','chat-pro','coder-pro','planner-pro')
    if ($restClean.Count -ge 2 -and $knownRoles -contains $restClean[0]) {
      $model = $restClean[0]
      $argList = @($restClean | Select-Object -Skip 1)
      $sysPrompt = $null; $promptParts = @(); $i = 0
      while ($i -lt $argList.Count) {
        if ($argList[$i] -eq '--sys' -and $i+1 -lt $argList.Count) {
          $sysPrompt = $argList[$i+1]; $i += 2
        } else { $promptParts += $argList[$i]; $i++ }
      }
      $messages = @()
      if ($sysPrompt) { $messages += @{ role='system'; content=$sysPrompt } }
      $messages += @{ role='user'; content=($promptParts -join ' ') }
      Invoke-BobStream -Model $model -Messages $messages -MaxTokens $maxTok -ApiBase $litellmBase | Out-Null
      Write-Host ""; break
    }

    # --- Smart routing ---
    $bobCfg = Get-BobConfig
    $targetRole = if     ($isPro -and $isThink) { $bobCfg.routing.proThinkRole ?? 'planner-pro' }
                  elseif ($isPro -and $isCode)  { $bobCfg.routing.proCodeRole  ?? 'coder-pro' }
                  elseif ($isPro)               { $bobCfg.routing.proRole      ?? 'chat-pro' }
                  elseif ($isThink)             { $bobCfg.routing.thinkRole    ?? 'planner' }
                  elseif ($isCode)              { $bobCfg.routing.codeRole     ?? 'coder' }
                  else                          { $bobCfg.routing.defaultRole  ?? 'chat' }

    $modelInfo   = (Get-Models).models | Where-Object role -eq $targetRole
    $displayName = if ($modelInfo) { ($modelInfo.gguf -replace '\.gguf$','') } else { $targetRole }

    # --- One-shot: prompt provided as arg ---
    if ($restClean.Count -gt 0) {
      $prompt  = $restClean -join ' '
      $messages = @(@{ role='system'; content=$bobCfg.persona.systemPrompt }, @{ role='user'; content=$prompt })
      $reply = Invoke-BobStream -Model $targetRole -Messages $messages -MaxTokens $maxTok -ApiBase $litellmBase -Raw:$isRaw
      if ($isRaw) { Write-Output $reply } else { Write-Host "" }
      break
    }

    # --- REPL mode ---
    Write-Host "Bob [$targetRole | $displayName]  (empty line to exit, !recall <query> to inject memory)" -ForegroundColor Cyan
    Write-Host ""
    $history    = [System.Collections.Generic.List[hashtable]]::new()
    $history.Add(@{ role='system'; content=$bobCfg.persona.systemPrompt })
    $memPs      = Join-Path $repo 'scripts\bob-memory.ps1'
    $memEnabled = $bobCfg.memory.enabled -and (Test-Path $memPs)
    $memSlotIdx = -1   # index of the single replaceable memory slot in $history

    try {
      while ($true) {
        $userInput = Read-Host '>'
        if ([string]::IsNullOrWhiteSpace($userInput)) { break }

        # !recall <query> — explicit memory injection, replaces previous slot
        if ($userInput -match '^!recall\s+(.+)$') {
          if (-not $memEnabled) { Write-Host "  [memory not enabled — set memory.enabled = `$true in config/bob.psd1]" -ForegroundColor DarkGray; continue }
          $q = $Matches[1].Trim()
          try {
            $memJson  = & $memPs recall $q 2>$null
            $memItems = $memJson | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($memItems -and $memItems.Count -gt 0) {
              $memText = '[Memory: ' + ($memItems | ForEach-Object { $_.content } | Join-String -Separator ' | ') + ']'
              if ($memSlotIdx -ge 0) { $history[$memSlotIdx] = @{ role='system'; content=$memText } }
              else { $history.Add(@{ role='system'; content=$memText }); $memSlotIdx = $history.Count - 1 }
              Write-Host "  [injected $($memItems.Count) memor$(if($memItems.Count -eq 1){'y'}else{'ies'}) into context]" -ForegroundColor DarkGray
            } else { Write-Host "  [no memories matched '$q']" -ForegroundColor DarkGray }
          } catch { Write-Host "  [memory recall failed: $_]" -ForegroundColor DarkGray }
          continue
        }

        # !memory — show DB status
        if ($userInput -eq '!memory') {
          if ($memEnabled) { try { & $memPs status 2>$null } catch {} } else { Write-Host "  [memory not enabled]" -ForegroundColor DarkGray }
          continue
        }

        $history.Add(@{ role='user'; content=$userInput })
        $reply = Invoke-BobStream -Model $targetRole -Messages $history.ToArray() -MaxTokens $maxTok -ApiBase $litellmBase
        Write-Host ""
        if ($reply) { $history.Add(@{ role='assistant'; content=$reply }) }
      }
    } finally {
      if ($memEnabled -and ($bobCfg.memory.autoSummarize -eq $true) -and ($history.Count -gt 2)) {
        Write-Host "  [summarizing session...]" -ForegroundColor DarkGray
        try {
          $tmpFile = [System.IO.Path]::GetTempFileName() + ".json"
          $history.ToArray() | ConvertTo-Json -Depth 4 | Set-Content $tmpFile -Encoding utf8
          & $memPs summarize-session --messages-file $tmpFile 2>$null
          Remove-Item $tmpFile -ErrorAction SilentlyContinue
        } catch {}
      }
      Write-Host "" -ForegroundColor DarkGray
    }
  }
  'code' {
    # bob code [--pro] [prompt] — alias for bob chat --code [--pro] [prompt]
    $fwd = @('--code') + $rest
    & "$PSScriptRoot\bob.ps1" chat @fwd
  }
  'think' {
    # bob think [--pro] [prompt] — alias for bob chat --think [--pro] [prompt]
    $fwd = @('--think') + $rest
    & "$PSScriptRoot\bob.ps1" chat @fwd
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
    $litellmPid = Join-Path $repo 'logs\litellm.pid'
    if (Test-Path $litellmPid) {
      $wPid = [int](Get-Content $litellmPid -Raw -ErrorAction SilentlyContinue)
      if ($wPid) { Get-Process -Id $wPid -ErrorAction SilentlyContinue | Stop-Process -Force }
      Remove-Item $litellmPid -ErrorAction SilentlyContinue
    }
    $whisperPid = Join-Path $repo 'logs\whisper.pid'
    if (Test-Path $whisperPid) {
      $wPid = [int](Get-Content $whisperPid -Raw -ErrorAction SilentlyContinue)
      if ($wPid) { Get-Process -Id $wPid -ErrorAction SilentlyContinue | Stop-Process -Force }
      Remove-Item $whisperPid -ErrorAction SilentlyContinue
    }
    $piperPid = Join-Path $repo 'logs\piper.pid'
    if (Test-Path $piperPid) {
      $wPid = [int](Get-Content $piperPid -Raw -ErrorAction SilentlyContinue)
      if ($wPid) { Get-Process -Id $wPid -ErrorAction SilentlyContinue | Stop-Process -Force }
      Remove-Item $piperPid -ErrorAction SilentlyContinue
    }
    Write-Host "Stopped endpoint + proxy + services (VRAM freed)." -ForegroundColor Green
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
    & "$repo\scripts\bob.ps1" bench
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
      default  { Write-Host "Usage: bob services start|stop|status|logs" }
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
  'remember' {
    if (-not $rest.Count) { Write-Host "usage: bob remember <text>"; break }
    & "$repo\scripts\bob-memory.ps1" store ($rest -join ' ')
  }
  'recall' {
    if (-not $rest.Count) { Write-Host "usage: bob recall <query>"; break }
    & "$repo\scripts\bob-memory.ps1" recall ($rest -join ' ')
  }
  'memory' {
    $sub   = if ($rest.Count) { $rest[0] } else { 'status' }
    $mRest = @($rest | Select-Object -Skip 1)
    switch ($sub) {
      'status' { & "$repo\scripts\bob-memory.ps1" status }
      'clear'  { & "$repo\scripts\bob-memory.ps1" clear @mRest }
      default  { Write-Host "Usage: bob memory status|clear [--yes]" }
    }
  }
  'budget' { & "$repo\scripts\bob-budget.ps1" }

  # ── Phase 2: Voice + Vision ─────────────────────────────────────────────────
  'setup-voice' { & "$repo\scripts\setup-voice.ps1" $(if ($rest -contains '-Force') { '-Force' }) }

  'listen' {
    $bobCfg  = Get-BobConfig
    $venvPy  = Join-Path $repo 'tools\venv-litellm\Scripts\python.exe'
    $capture = Join-Path $repo 'scripts\bob-voice-capture.py'
    $env:PYTHONIOENCODING = 'utf-8'
    & $venvPy $capture --port ($bobCfg.voice.sttPort ?? 8082) --silence-sec ($bobCfg.voice.silenceSec ?? 1.5)
    $env:PYTHONIOENCODING = $null
  }

  'transcribe' {
    if (-not $rest.Count) { Write-Host "usage: bob transcribe <audio-file>"; break }
    $bobCfg  = Get-BobConfig
    $venvPy  = Join-Path $repo 'tools\venv-litellm\Scripts\python.exe'
    $capture = Join-Path $repo 'scripts\bob-voice-capture.py'
    $env:PYTHONIOENCODING = 'utf-8'
    & $venvPy $capture --file $rest[0] --port ($bobCfg.voice.sttPort ?? 8082)
    $env:PYTHONIOENCODING = $null
  }

  'speak' {
    $bobCfg = Get-BobConfig
    $voice  = Join-Path $repo "bin\voices\$($bobCfg.voice.ttsVoice ?? 'en_US-lessac-medium').onnx"
    $piperExe = Join-Path $repo 'bin\piper.exe'
    if (-not (Test-Path $piperExe)) { Write-Host "piper.exe not found — run: bob setup-voice" -ForegroundColor Yellow; break }
    if (-not (Test-Path $voice))    { Write-Host "Voice model not found at $voice — run: bob setup-voice" -ForegroundColor Yellow; break }
    $text = if ($rest.Count) { $rest -join ' ' } else { $input | Out-String }
    if (-not $text -or -not $text.Trim()) { Write-Host "Nothing to speak." -ForegroundColor DarkGray; break }
    $tmpTxt = [IO.Path]::GetTempFileName()
    $tmpWav = $tmpTxt + '.wav'
    try {
      Set-Content $tmpTxt -Value $text -Encoding utf8 -NoNewline
      Get-Content $tmpTxt | & $piperExe --model $voice --output_file $tmpWav --quiet 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "piper exited with code $LASTEXITCODE" }
      (New-Object System.Media.SoundPlayer $tmpWav).PlaySync()
    } finally {
      Remove-Item $tmpTxt, $tmpWav -ErrorAction SilentlyContinue
    }
  }

  'describe' {
    $pro  = $rest -contains '--pro'
    $rest = @($rest | Where-Object { $_ -ne '--pro' })
    if (-not $rest.Count) { Write-Host "usage: bob describe <image> [--pro] [prompt]"; break }
    $imagePath = $rest[0]
    if (-not (Test-Path $imagePath)) { Write-Host "File not found: $imagePath" -ForegroundColor Red; break }
    $bobCfg   = Get-BobConfig
    $prompt   = if ($rest.Count -gt 1) { $rest[1..($rest.Count-1)] -join ' ' } else { 'Describe this image.' }
    # Resize image to max 1024px on longest edge — large screenshots exceed context limits.
    Add-Type -AssemblyName System.Drawing
    $srcBmp  = [Drawing.Bitmap]::new($imagePath)
    $maxDim  = 1024
    $scale   = [Math]::Min($maxDim / $srcBmp.Width, $maxDim / $srcBmp.Height)
    $scale   = [Math]::Min($scale, 1.0)   # never upscale
    $w = [int]($srcBmp.Width  * $scale)
    $h = [int]($srcBmp.Height * $scale)
    $resizedTmp = $null
    if ($scale -lt 1.0) {
      $dstBmp = [Drawing.Bitmap]::new($w, $h)
      $g = [Drawing.Graphics]::FromImage($dstBmp)
      $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $g.DrawImage($srcBmp, 0, 0, $w, $h)
      $g.Dispose(); $srcBmp.Dispose()
      $resizedTmp = [IO.Path]::GetTempFileName() + '.png'
      $dstBmp.Save($resizedTmp, [Drawing.Imaging.ImageFormat]::Png)
      $dstBmp.Dispose()
      $imagePath = $resizedTmp
    } else {
      $srcBmp.Dispose()
    }
    try {
      $b64  = [Convert]::ToBase64String([IO.File]::ReadAllBytes($imagePath))
      $ext  = [IO.Path]::GetExtension($imagePath).TrimStart('.').ToLower()
      $mime = if ($ext -eq 'jpg') { 'jpeg' } else { $ext }
      $messages = @(@{
        role    = 'user'
        content = @(
          @{ type = 'image_url'; image_url = @{ url = "data:image/$mime;base64,$b64" } },
          @{ type = 'text';      text      = $prompt }
        )
      })
      $vRole = if ($pro) { $bobCfg.vision.visionProRole ?? 'vision-pro' } else { $bobCfg.vision.visionRole ?? 'vision' }
      Invoke-BobStream -Model $vRole -Messages $messages -MaxTokens ($d.maxTokens ?? 512) -ApiBase $litellmBase | Out-Null
      Write-Host ""
    } finally {
      if ($resizedTmp) { Remove-Item $resizedTmp -ErrorAction SilentlyContinue }
    }
  }

  'screenshot' {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $screen = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp    = [Drawing.Bitmap]::new($screen.Width, $screen.Height)
    $g      = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($screen.Location, [Drawing.Point]::Empty, $screen.Size)
    $tmp = [IO.Path]::GetTempFileName() + '.png'
    $bmp.Save($tmp, [Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    try {
      $descArgs = @('describe', $tmp) + $rest
      & "$PSScriptRoot\bob.ps1" @descArgs
    } finally {
      Remove-Item $tmp -ErrorAction SilentlyContinue
    }
  }

  'voice' {
    $bobCfg   = Get-BobConfig
    $pro      = $rest -contains '--pro'
    $voiceSys  = $bobCfg.voice.systemPrompt ?? $bobCfg.persona.systemPrompt
    $voiceRole = if ($pro) { $bobCfg.routing.proRole ?? 'chat-pro' } else { $bobCfg.routing.defaultRole ?? 'chat' }
    $voiceTok  = $bobCfg.voice.maxTokens ?? 256
    Write-Host "Bob voice loop — Ctrl+C to exit. Use headphones to avoid echo." -ForegroundColor Cyan
    Write-Host "Model: $voiceRole" -ForegroundColor DarkGray
    # Conversation history persists for the duration of the voice session.
    $messages = @(@{ role = 'system'; content = $voiceSys })
    try {
      while ($true) {
        Write-Host "Listening..." -ForegroundColor DarkGray
        $transcript = & "$PSScriptRoot\bob.ps1" listen
        if (-not $transcript -or -not $transcript.Trim()) { continue }
        Write-Host "> $transcript" -ForegroundColor Yellow
        # /no_think: Qwen3 skips reasoning scratchpad — voice needs fast replies.
        $messages += @{ role = 'user'; content = "$transcript /no_think" }
        $response = Invoke-BobStream -Model $voiceRole -Messages $messages -MaxTokens $voiceTok -ApiBase $litellmBase -Raw
        # Strip trailing non-ASCII residue (Qwen3 leaks special-token bytes at end of raw stream).
        $response = [regex]::Replace($response.Trim(), '[-￿]+$', '')
        $response = Format-ForSpeech $response
        if ($response) {
          Write-Host "Bob: $response" -ForegroundColor Cyan
          $messages += @{ role = 'assistant'; content = $response }
          & "$PSScriptRoot\bob.ps1" speak $response
        }
      }
    } finally {
      Write-Host "`nVoice loop ended." -ForegroundColor DarkGray
    }
  }
  'whisper' {
    $subCmd  = if ($rest.Count -and $rest[0] -in 'stop','start','status') { $rest[0] } else { '' }
    $whisperPidFile = Join-Path $repo 'logs\whisper.pid'
    $sttPort = try { (Get-BobConfig).voice.sttPort ?? 8082 } catch { 8082 }
    switch ($subCmd) {
      'stop' {
        if (Test-Path $whisperPidFile) {
          $wPid = [int](Get-Content $whisperPidFile -Raw)
          Get-Process -Id $wPid -ErrorAction SilentlyContinue | Stop-Process -Force
          Remove-Item $whisperPidFile -ErrorAction SilentlyContinue
          Write-Host "whisper-server stopped." -ForegroundColor Green
        } else { Write-Host "whisper-server not running." -ForegroundColor DarkGray }
      }
      'status' {
        if (Test-Path $whisperPidFile) {
          $wPid = [int](Get-Content $whisperPidFile -Raw)
          $proc = Get-Process -Id $wPid -ErrorAction SilentlyContinue
          if ($proc) {
            $uptime = ([DateTime]::Now - $proc.StartTime).ToString('hh\:mm\:ss')
            Write-Host "whisper-server running  PID=$wPid  uptime=$uptime  http://localhost:$sttPort" -ForegroundColor Green
          } else { Write-Host "whisper-server dead (stale PID $wPid)." -ForegroundColor Red }
        } else { Write-Host "whisper-server not running." -ForegroundColor DarkGray }
      }
      default { & "$repo\scripts\start-whisper.ps1" $(if ($rest -contains '-NoWindow') { '-NoWindow' }) }
    }
  }

  'piper' {
    $subCmd = if ($rest.Count -and $rest[0] -in 'stop','start','status') { $rest[0] } else { '' }
    $piperPidFile = Join-Path $repo 'logs\piper.pid'
    $ttsPort = try { (Get-BobConfig).voice.ttsPort ?? 8083 } catch { 8083 }
    switch ($subCmd) {
      'stop' {
        if (Test-Path $piperPidFile) {
          $wPid = [int](Get-Content $piperPidFile -Raw)
          Get-Process -Id $wPid -ErrorAction SilentlyContinue | Stop-Process -Force
          Remove-Item $piperPidFile -ErrorAction SilentlyContinue
          Write-Host "piper-server stopped." -ForegroundColor Green
        } else { Write-Host "piper-server not running." -ForegroundColor DarkGray }
      }
      'status' {
        if (Test-Path $piperPidFile) {
          $wPid = [int](Get-Content $piperPidFile -Raw)
          $proc = Get-Process -Id $wPid -ErrorAction SilentlyContinue
          if ($proc) {
            $uptime = ([DateTime]::Now - $proc.StartTime).ToString('hh\:mm\:ss')
            Write-Host "piper-server running  PID=$wPid  uptime=$uptime  http://localhost:$ttsPort" -ForegroundColor Green
          } else { Write-Host "piper-server dead (stale PID $wPid)." -ForegroundColor Red }
        } else { Write-Host "piper-server not running." -ForegroundColor DarkGray }
      }
      default { & "$repo\scripts\start-piper-server.ps1" $(if ($rest -contains '-NoWindow') { '-NoWindow' }) }
    }
  }

  default {
    $wp = $d.webuiPort ?? 3000
@"
bob — personal AI assistant (endpoint $base)

Inference:
  bob serve                            Start API endpoint (:$port) — interactive, Ctrl+C to stop
  bob up [-NoOpen]                     Start endpoint + Open WebUI silently [+ browser]
  bob stop                             Stop all services (frees VRAM)
  bob restart                          Stop then start endpoint (interactive)
  bob status                           Loaded models and VRAM usage
  bob ps                               Daemon processes with PID, RAM, uptime
  bob logs [-n N]                      Tail server log (default: last 50 lines)

Chat:
  bob chat                             Interactive REPL (chat role, Ctrl+C to exit)
  bob chat [--pro] [--think] [--code]  REPL with routed role
  bob chat "prompt"                    One-shot with default role
  bob chat <role> "prompt"             One-shot legacy syntax (still works)
  bob think [--pro] ["prompt"]         Alias: planner / planner-pro
  bob code  [--pro] ["prompt"]         Alias: coder / coder-pro
  bob remember "fact"                  Store text to memory
  bob recall "query"                   Search memory
  bob memory status|clear              Memory DB info / wipe
  bob budget                           Token and cost usage summary

Models:
  bob models                           List models with backing names and state
  bob show <role>                      Model info: file, VRAM, SHA256, disk status
  bob bench [gguf]                     Throughput benchmark

Management:
  bob profiles                         List VRAM profiles with sizes and active marker
  bob profile <name|auto>              Switch profile (auto = detect from GPU VRAM)
  bob fetch [--list] [profile]         Download models for active/specified profile
  bob verify-urls [<profile>]          Check HuggingFace download URLs
  bob update                           Pull latest llama.cpp and rebuild
  bob gen                              Regenerate config/llama-swap.yaml

Tools:
  bob aider [args]                     Start aider in current folder
  bob webui                            Launch Open WebUI only (:$wp)
  bob diagnose                         System and model health check
  bob mlock                            Check/grant SeLockMemoryPrivilege (needed for --mlock)
  bob version                          Show binary versions and submodule commits

Ecosystem:
  bob fabric-setup                     Install fabric and configure it for the local endpoint
  bob litellm [start]                  Start LiteLLM proxy (:8081) — API gateway + retry layer
  bob litellm stop                     Stop LiteLLM proxy
  bob litellm status                   Check if LiteLLM proxy is running
  bob services start|stop|status|logs  Docker services: Langfuse (:3001) SearXNG (:8888) n8n (:5678)
  bob eval <role> [task]               Benchmark model quality (mmlu, humaneval, gsm8k)

Voice (requires: bob setup-voice + voice.enabled = `$true in bob.psd1):
  bob setup-voice                      Download piper + whisper model, build whisper-server
  bob listen                           Record mic until silence, print transcript
  bob transcribe <file>                Transcribe audio file via whisper-server
  bob speak ["text"]                   Synthesize text to audio (reads stdin if no arg)
  bob voice [--pro]                    Continuous voice loop: listen -> chat -> speak
  bob whisper [start]                  Start whisper-server (STT, :8082) — WebUI STT source
  bob whisper stop|status              Stop / check whisper-server
  bob piper [start]                    Start piper TTS HTTP server (:8083) — WebUI TTS source
  bob piper stop|status                Stop / check piper-server

Vision (requires: bob setup-voice + bob fetch + vision.enabled = `$true in bob.psd1):
  bob describe <image> [--pro] [prompt]  Describe image (local Qwen2-VL or --pro DeepSeek V4)
  bob screenshot [--pro] [prompt]        Capture screen and describe it (--pro for cloud vision)
"@
  }
}
