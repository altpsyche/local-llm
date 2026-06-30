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
    defaultRole  = 'chat'          # `bob chat` default role
    proRole      = 'chat-pro'      # `bob chat --pro` target
    thinkRole    = 'planner'       # `bob think` / `bob chat --think`
    proThinkRole = 'planner-pro'   # `bob think --pro` / `bob chat --think --pro`
    codeRole     = 'coder'         # `bob code`
    proCodeRole  = 'coder-pro'     # `bob code --pro` / `bob chat --code --pro`
    agentRole    = 'agent'         # `bob agent` — Hermes 3 function-calling model
    autoFallback = $false          # $true = fall back to local if cloud fails
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
    sttModel    = 'small'
    ttsEngine   = 'piper'            # piper | llama-tts
    ttsVoice    = 'en_GB-alan-medium'
    ttsPort     = 8083               # piper HTTP server port (bob piper / WebUI TTS)
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

  vision = @{
    enabled       = $true            # Phase 2 vision active (requires bob fetch for models)
    visionRole    = 'vision'
    visionProRole = 'vision-pro'     # routes to DeepSeek V4 (supports vision) via --pro flag
  }

  agent = @{
    enabled           = $false              # flip to $true to activate scheduled tasks
    agency            = 'show'             # 'silent' | 'show' | 'confirm'
    toolFormat        = 'hermes'           # 'hermes' (XML tool_call) | 'openai' (JSON tool_calls)
    maxSteps          = 10
    maxHistoryMsgs    = 40                 # sliding window — prevents token overflow on long runs
    tools             = @('memory', 'web', 'git', 'file', 'shell', 'fabric', 'play', 'summarise', 'draft', 'search')
    allowedReadPaths  = @()    # defaults to repo root at runtime; add more paths in user.psd1
    allowedWritePaths = @()                # file_write disabled by default
    agentPort         = 8084   # bob agent serve HTTP port (for WebUI/n8n integration)
    scheduleFile      = 'data\schedules.json'
    logFile           = 'logs\bob-agent.log'
    toastAppId        = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\powershell.exe'
    maxResultChars    = 500
    # MCP integration hook (Phase 4+):
    # mcpEnabled = $false
    # mcpServers = @('filesystem', 'fetch', 'github', 'searxng')
  }
}
