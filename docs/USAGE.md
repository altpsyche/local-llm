# USAGE

## One-time setup
```powershell
.\scripts\setup-clients.ps1    # wire VS Code Continue + aider to the repo configs (symlink/copy)
```
Run once per machine. Open WebUI needs nothing here — it's auto-wired at launch by `up.ps1`.

## Daily: start everything (one command)
```powershell
.\scripts\up.ps1               # endpoint :8080 + Open WebUI :3000, in two windows
```
Or just the endpoint (for IDE/CLI/your scripts, no UI):
```powershell
.\scripts\start.ps1            # llama-swap on http://localhost:8080/v1
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

## VS Code — Continue.dev (autocomplete + chat)
`setup-clients.ps1` links `config/continue/config.yaml` to `~/.continue/config.yaml`. Just install the
**Continue** extension. Roles: `chat/edit/apply` → `coder` (plus a `planner` entry for heavy chats),
`autocomplete` → `fim`, `embed` → `embed`.

## VS Code — Cline (agentic)
Settings → API Provider **OpenAI Compatible** → Base URL `http://localhost:8080/v1`, key `sk-local`, Model ID `coder`.
⚠️ Cline's *distinct Plan/Act models* are broken on OpenAI-compatible endpoints (bug #8126) — run single-model.
For planner≠editor, use aider (below).

## Terminal — aider (plan ≠ edit, architect mode)
`setup-clients.ps1` links `config/aider/.aider.conf.yml` to `~/.aider.conf.yml`, so just run:
```powershell
.\tools\venv-aider\Scripts\aider          # planner drafts, coder applies — config auto-loaded
```

## General chat + RAG — Open WebUI
Launched by `up.ps1` on **:3000**, pre-wired via env vars (connection `http://localhost:8080/v1`,
RAG embedding model `embed`) — no manual Admin setup. To run it standalone:
```powershell
.\tools\venv-webui\Scripts\open-webui serve --port 3000
```
Optional presets: Workspace → Models → a "Planner" preset (base `planner`, low temp) and a "Chat" preset (base `chat`).

## Per-role model separation (no code)
- **llama-swap**: add a named entry in `config/llama-swap.yaml`.
- **Continue**: add a model with the desired `roles:`.
- **aider**: `architect: true` + `model:` (planner) + `editor-model:` (editor).
- **Open WebUI / AnythingLLM**: presets / per-workspace model.
