# USAGE

## Start the endpoint
```powershell
.\scripts\start.ps1            # llama-swap on http://localhost:8080/v1
```
Models load on first request and unload when idle (except `fim` + `embed`, pinned). One big model
(`planner`/`coder`/`chat`) is resident at a time; `fim` + `embed` stay alongside.

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
Config lives at `config/continue/config.yaml` (roles assign models). Activate it:
```powershell
New-Item -ItemType SymbolicLink -Path $HOME\.continue\config.yaml -Target C:\local-llm\config\continue\config.yaml
```
Roles: `chat/edit/apply` → `coder` (and a `planner` entry for heavy chats), `autocomplete` → `fim`, `embed` → `embed`.

## VS Code — Cline (agentic)
Settings → API Provider **OpenAI Compatible** → Base URL `http://localhost:8080/v1`, key `sk-local`, Model ID `coder`.
⚠️ Cline's *distinct Plan/Act models* are broken on OpenAI-compatible endpoints (bug #8126) — run single-model.
For planner≠editor, use aider (below).

## Terminal — aider (plan ≠ edit, architect mode)
Config at `config/aider/.aider.conf.yml` (`planner` drafts, `coder` edits). Run:
```powershell
.\tools\venv312\Scripts\aider --config C:\local-llm\config\aider\.aider.conf.yml
```

## General chat + RAG — Open WebUI
```powershell
.\tools\venv312\Scripts\open-webui serve --port 3000        # browser: http://localhost:3000
```
- Admin → Settings → Connections → OpenAI → add `http://localhost:8080/v1` (key `sk-local`).
- RAG: set the embedding model to `embed`. Upload docs, ask grounded questions.
- Presets: Workspace → Models → make a "Planner" preset (base `planner`, low temp) and a "Chat" preset (base `chat`).

## Per-role model separation (no code)
- **llama-swap**: add a named entry in `config/llama-swap.yaml`.
- **Continue**: add a model with the desired `roles:`.
- **aider**: `architect: true` + `model:` (planner) + `editor-model:` (editor).
- **Open WebUI / AnythingLLM**: presets / per-workspace model.
