# Bob persona and behavior configuration.
# Committed with defaults (the persona is part of the product).
# Override any key in config/user.psd1 under a 'bob' section.
#
# Loaded by scripts/_models.ps1 via Get-BobConfig (added in Phase 1).
# Phase 0: stub — reserved schema, no runtime effect yet.
@{
  persona = @{
    name         = 'Bob'
    systemPrompt = @'
You are Bob, a personal AI assistant running privately on this machine. You are direct, practical, and you remember what matters. You assist with software development, writing, planning, and daily work. Relevant memories from past sessions are provided in context when available. When you don't know something, say so.
'@
    style        = 'direct'    # direct | friendly | formal
  }

  routing = @{
    defaultRole  = 'chat'      # `bob chat` default role
    proRole      = 'chat-pro'  # `bob chat --pro` target
    thinkRole    = 'planner'   # `bob think` / `bob chat --think`
    codeRole     = 'coder'     # `bob code`
    autoFallback = $false      # $true = fall back to local if cloud fails
  }

  memory = @{
    enabled          = $false      # flip to $true to activate (Phase 1)
    dbPath           = 'data\bob.db'
    embedModel       = 'embed'     # BGE-M3 — already pinned at :8081
    recallK          = 5
    maxSummaryTokens = 256
    autoSummarize    = $true
  }

  voice = @{
    enabled     = $true              # Phase 2 voice active
    sttPort     = 8082
    sttModel    = 'whisper-base.en'
    ttsEngine   = 'piper'            # piper | llama-tts
    ttsVoice    = 'en_US-lessac-medium'
    silenceSec  = 1.5                # seconds of silence before mic stops recording
  }

  vision = @{
    enabled    = $true               # Phase 2 vision active (requires bob fetch for models)
    visionRole = 'vision'
  }

  proactive = @{
    enabled      = $false          # Phase 3
    scheduleFile = 'data\schedules.json'
  }
}
