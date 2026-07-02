# Bob persona and behavior configuration — the Windows OVERLAY on config/defaults.json.runtime.
# Override any key in config/user.psd1 under a 'bob' section.
#
# NB7 (Option A): the runtime defaults (persona.systemPrompt, memory, vision, agent.*) live in the
# neutral config/defaults.json 'runtime' layer — the single source shared with the Python resolver.
# Get-BobConfig seeds from there and deep-merges this file, so this psd1 carries ONLY the keys that
# are Windows-specific or not part of the neutral runtime: persona.name/style, routing, the whole
# voice block, and agent.toastAppId. Do NOT re-add memory/vision/other agent keys here — change them
# in config/defaults.json (both OSes) or override per-machine in config/user.psd1.
@{
  persona = @{
    name  = 'Bob'
    style = 'direct'    # direct | friendly | formal
    # systemPrompt lives in config/defaults.json.runtime.persona (shared with the Python resolver).
  }

  routing = @{
    defaultRole  = 'chat'          # `bob chat` default role
    proRole      = 'chat-pro'      # `bob chat --pro` target
    thinkRole    = 'planner'       # `bob think` / `bob chat --think`
    proThinkRole = 'planner-pro'   # `bob think --pro` / `bob chat --think --pro`
    codeRole     = 'coder'         # `bob code`
    proCodeRole  = 'coder-pro'     # `bob code --pro` / `bob chat --code --pro`
    agentRole    = 'agent'         # `bob agent` — Hermes 3 function-calling model
    autoFallback = $false          # $true = fall back to local if cloud fails
  }

  voice = @{
    enabled     = $true              # Phase 2 voice active
    # sttPort/ttsPort single-sourced in config/defaults.json (NB1/C2) — resolve via Get-BobPortDefault.
    sttModel    = 'small'
    ttsEngine   = 'piper'            # piper | llama-tts
    ttsVoice    = 'en_GB-alan-medium'
    silenceSec  = 1.5                # seconds of silence before mic stops recording
    maxTokens   = 512                # keep voice replies short
    # System prompt for voice mode only — plain spoken language, no markdown.
    # Overrides persona.systemPrompt in the voice loop.
    systemPrompt = @'
You are Bob, a voice assistant. Reply in natural spoken sentences only.
Never use markdown: no asterisks, no bullet points, no pound signs, no backticks, no numbered lists, no dashes as bullets, no special symbols.
If you need to list things, say "first", "then", "finally" or similar spoken connectives.
Keep answers brief and direct. One to three sentences is ideal.
'@
  }

  agent = @{
    # All agent runtime keys (enabled, agency, maxSteps, timeouts, paths, ports, tokens, …) live in
    # config/defaults.json.runtime.agent. Only toastAppId is Windows-specific and stays here.
    toastAppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\powershell.exe'
  }
}
