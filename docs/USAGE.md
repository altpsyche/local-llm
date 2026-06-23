# USAGE

## One-time setup
```powershell
.\scripts\setup-clients.ps1    # wire VS Code Continue + aider to the repo configs (symlink/copy)
```
Run once per machine. Open WebUI needs nothing here — it's auto-wired at launch by `up.ps1`.

## The `llm` command (installed on PATH by setup)
```
llm up                   start endpoint :8080 + Open WebUI :3000
llm serve                endpoint only (:8080)
llm stop                 stop the endpoint (frees VRAM)
llm aider [args]         aider architect mode in the current folder
llm webui                Open WebUI only (:3000)
llm chat <model> <text>  one-shot chat   e.g.  llm chat coder "write fizzbuzz"
llm models               list model names
llm bench [gguf]         throughput benchmark
```
(Run `scripts\install-cli.ps1` if `llm` isn't found; open a fresh terminal after.)

## Daily: start everything
```powershell
llm up        # endpoint :8080 + Open WebUI :3000, in two windows
# or just the endpoint for IDE/CLI/scripts:
llm serve     # llama-swap on http://localhost:8080/v1
```
Models load on first request and unload when idle (except `fim` + `embed`, pinned). One big model
(`planner`/`coder`/`chat`) is resident at a time; `fim` + `embed` stay alongside.

> Want it to auto-start at login? Put a shortcut to `up.ps1` in `shell:startup`, or create a Task
> Scheduler task "At log on" running `pwsh -File C:\local-llm\scripts\up.ps1`.

## Models exposed
| `model:` | Role | Backing GGUF |
|---|---|---|
| `planner` | heavy reasoning / architect | Qwen3-30B-A3B Q4 |
| `coder` | coding chat + agentic edits | Qwen2.5-Coder-14B Q4_K_M |
| `chat` | general chat | Qwen3-14B Q4_K_M |
| `fim` | autocomplete | Qwen-Coder-3B Q8_0 |
| `embed` | RAG embeddings | bge-m3 Q8 |

## Raw API / your own scripts
```powershell
curl http://localhost:8080/v1/chat/completions -H "Content-Type: application/json" -d '{
  "model": "coder", "messages": [{"role":"user","content":"write a fizzbuzz in rust"}] }'
```

> **Qwen3 thinking mode:** `chat`/`planner` (Qwen3) reason in a hidden block first, which can
> consume your whole `max_tokens` and leave `content` empty. Either give plenty of tokens (512+),
> or append `/no_think` to your prompt for a fast direct answer. GUI clients (Open WebUI) show/collapse
> the reasoning automatically, so this only bites raw API calls with small `max_tokens`.

## VS Code — Continue.dev (autocomplete + chat)
`setup-clients.ps1` links `config/continue/config.yaml` to `~/.continue/config.yaml`. Just install the
**Continue** extension. Roles: `chat/edit/apply` → `coder` (plus a `planner` entry for heavy chats),
`autocomplete` → `fim`, `embed` → `embed`.

## VS Code — Cline (agentic)
Settings → API Provider **OpenAI Compatible** → Base URL `http://localhost:8080/v1`, key `sk-local`, Model ID `coder`.
⚠️ Cline's *distinct Plan/Act models* are broken on OpenAI-compatible endpoints (bug #8126) — run single-model.
For planner≠editor, use aider (below).

## Terminal — aider (plan ≠ edit, architect mode)
`setup-clients.ps1` links `config/aider/.aider.conf.yml` to `~/.aider.conf.yml`. From any project folder:
```powershell
cd <your-project>
llm aider          # planner drafts, coder applies — config auto-loaded
```

## General chat + RAG — Open WebUI
`llm up` launches it on **:3000**, pre-wired via env (connection `http://localhost:8080/v1`,
RAG embedding model `embed`) — no manual Admin setup. Standalone: `llm webui`.
Optional presets: Workspace → Models → a "Planner" preset (base `planner`, low temp) and a "Chat" preset (base `chat`).

## Per-role model separation (no code)
- **llama-swap**: add a named entry in `config/llama-swap.yaml`.
- **Continue**: add a model with the desired `roles:`.
- **aider**: `architect: true` + `model:` (planner) + `editor-model:` (editor).
- **Open WebUI / AnythingLLM**: presets / per-workspace model.
