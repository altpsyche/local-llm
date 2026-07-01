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
    maxHistoryMsgs    = 40                 # sliding window (message count) — first-pass overflow guard
    maxContextTokens  = 6000               # M7: token budget for history; drops oldest turns first (0 = count-only). Keep < agent model ctx.
    maxToolResultTokens = 1000             # M7: per-tool-result cap (~4 chars/token) before appending to history
    compactSchemasAfter = 12               # M7: above this many tools, inject compact schemas (drop param descriptions) to bound prompt size
    requestTimeout    = 600                # client-side LLM call timeout (s); must be >= litellm request_timeout so thinking models aren't cut off
    allowPrivateFetch = $false             # M9: web_fetch blocks loopback/private/link-local hosts unless $true (SSRF guard)
    disabledTools     = @()    # list tool names here to exclude them from the agent
    allowedReadPaths  = @()    # defaults to repo root at runtime; add more paths in user.psd1
                               # N9: file_read/file_write always refuse config.json, *.psd1, *.db,
                               # logs/, .env* even inside an allowed root (secrets denylist)
    allowedWritePaths = @()                # file_write disabled by default
    gitAllowedRoots   = @()    # N9: extra repos git_* may read (status/log/diff); repo root always allowed
    agentPort         = 8084   # bob agent serve HTTP port (for WebUI/n8n integration)
    serveHost         = '127.0.0.1'  # bob agent serve bind address; set '0.0.0.0' to expose on LAN (harden web_fetch first)
    # N1: per-client Bearer tokens, each mapped to an owner id. Sessions are owner-scoped —
    # a token can only see/modify sessions its owner created (others 404). The litellmKey maps
    # to defaultOwner. Shape: @{ token = 'sk-alice-...'; owner = 'alice' }  (bare strings also
    # accepted for legacy: token maps to itself as owner). Revoke = remove entry + restart serve.
    apiTokens         = @()
    defaultOwner      = 'local'  # N1: owner id the litellmKey (and unlabeled sessions) map to
    sessionDbPath     = 'data\sessions.db'  # M12: SQLite store for multi-turn agent sessions
    maxSessionTokens  = 0      # M12: per-session token budget for `bob agent serve` sessions (0 = unlimited)
    scheduleFile      = 'data\schedules.json'
    logFile           = 'logs\bob-agent.log'
    logMaxBytes       = 5000000  # N5: rotate bob-agent.log at ~5 MB
    logBackupCount    = 3        # N5: keep this many rotated logs
    toastAppId        = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\powershell.exe'
    maxResultChars    = 500
    mcpEnabled        = $false   # N10: `bob agent mcp` exposes Bob's tools over MCP (stdio) when $true
  }
}
