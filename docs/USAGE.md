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
llm profiles             list VRAM profiles + which is active
llm profile <name>       switch profile (e.g. llm profile 12gb) — regenerates config
llm fetch [--list] [p]   download models for a profile (--list = dry-run)
llm gen                  regenerate config/llama-swap.yaml from config/models.psd1
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

## Models exposed (`16gb` profile)
| `model:` | Role | Backing GGUF |
|---|---|---|
| `planner` | heavy reasoning / architect | Qwen3-30B-A3B Q4 |
| `coder` | coding chat + agentic edits | Qwen2.5-Coder-14B Q4_K_M |
| `chat` | general chat | Qwen3-14B Q4_K_M |
| `fim` | autocomplete | Qwen-Coder-3B Q8_0 |
| `embed` | RAG embeddings | bge-m3 Q8 |

Every model — its GGUF, HuggingFace source, context size, and flags — is defined once in
[config/models.psd1](../config/models.psd1). The downloader and the runtime config
(`config/llama-swap.yaml`, generated) both derive from it. Clients reference only the role names
above, so swapping the backing model never touches client config.

**Low on VRAM?** Ship-with profiles: `16gb` (default, the verified set, ~38 GB on disk) and `12gb`
(smaller quants, ~21 GB). Switch in one line — `llm profile 12gb`, or `setup.bat -Profile 12gb` before
setup. (`32gb`/`64gb` can be added later in `config/models.psd1`.) See `llm profiles` and the
[Per-role model separation](#per-role-model-separation-no-code) section.

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
`setup-clients.ps1` links `config/continue/config.yaml` → `~/.continue/config.yaml`, so all four roles
are wired with **zero in-editor setup**.

**Setup**
1. `.\scripts\setup-clients.ps1` (once per machine — links the config; copies instead if you lack
   symlink privilege, see note below).
2. Install the **Continue** extension from the VS Code Marketplace.
3. `llm serve` (or `llm up`) so the endpoint is live on `:8080`.
4. Open the Continue panel (sidebar icon, or `Ctrl+L`). It should already list `coder` / `planner`.

**Role → model map** (from `config/continue/config.yaml`)
| Continue role | Model entry | llama-swap `model:` | Use |
|---|---|---|---|
| `chat`, `edit`, `apply` | `coder` | `coder` (Qwen2.5-Coder-14B) | default coding chat + inline edits |
| `chat`, `edit` | `planner` | `planner` (Qwen3-30B-A3B) | heavy reasoning / architecture chats |
| `autocomplete` | `autocomplete` | `fim` (Qwen-Coder-3B, pinned) | as-you-type completions |
| `embed` | `embeddings` | `embed` (bge-m3, pinned) | `@codebase` / `@docs` RAG indexing |

**Keys & actions**
- `Ctrl+L` — new chat (selection auto-attached as context).
- `Ctrl+I` — inline edit on the selected lines; review diff, then accept/reject.
- Autocomplete fires automatically as ghost text; `Tab` accepts. Served by `fim` (pinned, so it stays
  warm and never evicts the big model).
- `@codebase`, `@file`, `@docs` in chat pull RAG context via the `embed` model.
- Switch chat model with the dropdown at the bottom of the chat box — pick `planner` for design/architecture,
  `coder` for everyday edits.

**Notes**
- Context window is 16384 tokens for `coder`/`planner` (`ctx` in `config/models.psd1`). Large
  `@codebase` queries get truncated to fit — narrow with `@file` when precision matters.
- First message to a model is slow (loads to VRAM). `fim` + `embed` stay pinned, so autocomplete and
  RAG never trigger a reload; only switching between `coder`/`planner`/`chat` swaps the resident model.
- Edited the repo config but using a **copied** (not symlinked) `~/.continue/config.yaml`? Re-run
  `setup-clients.ps1` after deleting the copy, or edit `~/.continue/config.yaml` directly.

## VS Code — Cline (agentic)
Cline is **not** auto-wired — configure it once in its settings.

**Setup**
1. Install the **Cline** extension.
2. `llm serve` (endpoint on `:8080`).
3. Cline → ⚙️ Settings → **API Provider** = `OpenAI Compatible`:
   | Field | Value |
   |---|---|
   | Base URL | `http://localhost:8080/v1` |
   | API Key | `sk-local` (any non-empty string works; llama-swap ignores it) |
   | Model ID | `coder` |
4. Set **context window** to `16384` (matches `ctx` for `coder` in `config/models.psd1`) so Cline doesn't
   overflow the server and stall. Enable image support only if the model is multimodal — these aren't.

**⚠️ Single-model only.** Cline's distinct **Plan/Act** models are broken on OpenAI-compatible endpoints
([cline#8126](https://github.com/cline/cline/issues/8126)). Use **one** model (`coder`) for both modes.
Want a real planner≠editor split? Use **aider** (below) — it runs `planner` for design and `coder` for edits.

**Notes**
- Cline is agentic: it reads/writes files and runs commands across many turns, so it burns through the
  16k context fast. Keep tasks scoped; start a fresh task when the history balloons.
- Want stronger reasoning for a hard task? Set Model ID to `planner` instead of `coder` (slower, but the
  30B model plans better). Switching evicts the other big model from VRAM.

## Terminal — aider (plan ≠ edit, architect mode)
The one client with a **true planner≠editor split**: `planner` (Qwen3-30B) drafts the change, `coder`
(Qwen2.5-Coder-14B) writes the diff. This is the workaround for Cline's broken Plan/Act split.

**Setup**
1. `.\scripts\setup-clients.ps1` links `config/aider/.aider.conf.yml` → `~/.aider.conf.yml`. aider
   auto-discovers it from home / git root / cwd — no `--config` flag needed.
2. `llm serve` (endpoint on `:8080`).
3. From any project:
   ```powershell
   cd <your-project>
   llm aider          # config auto-loaded
   ```

**How architect mode flows** (from `config/aider/.aider.conf.yml`)
- `architect: true` — `planner` proposes the change in prose, then `coder` turns it into a `diff` edit.
- `auto-accept-architect: false` — you **review the plan before any edit lands**. Press Enter to apply,
  or refine first.
- Both models go through one endpoint; aider swaps `planner`↔`coder` per step, so each turn triggers a
  VRAM swap between them (a few seconds). That's the cost of the split.

**In-session commands**
| Command | Does |
|---|---|
| `/add <file>` | put a file in the editable context |
| `/read <file>` | add a file as read-only reference |
| `/ask <q>` | question without editing |
| `/diff` | show pending changes |
| `/undo` | revert aider's last commit |
| `/drop` | shrink context when it gets big |

**Notes**
- Local OpenAI-compatible models **must** be prefixed `openai/` in the config (`openai/planner`,
  `openai/coder`) — case-sensitive, already set.
- aider auto-commits each accepted edit to git. Work on a branch; `/undo` rolls back the last one.
- 16k context per model — use `/drop` and `/read` (vs `/add`) to keep it lean on big repos.

## General chat + RAG — Open WebUI
`llm up` launches it on **:3000**, pre-wired via env (connection `http://localhost:8080/v1`,
RAG embedding model `embed`) — no manual Admin setup. Standalone: `llm webui`.
Optional presets: Workspace → Models → a "Planner" preset (base `planner`, low temp) and a "Chat" preset (base `chat`).

## Per-role model separation (no code)
- **Models / profiles**: edit [config/models.psd1](../config/models.psd1) — the single source. Add or
  retune a model under a profile (or add a whole profile), then `llm gen` (or just `llm serve`, which
  regenerates `config/llama-swap.yaml` on launch). `config/llama-swap.yaml` is **generated — do not edit
  it by hand** (it's overwritten on every launch and is gitignored).
- **Continue**: add a model with the desired `roles:`.
- **aider**: `architect: true` + `model:` (planner) + `editor-model:` (editor).
- **Open WebUI / AnythingLLM**: presets / per-workspace model.

### Changing the active profile
`config/models.psd1` ships two profiles; `activeProfile` selects one. Three ways to switch:
- **Edit one line** (before setup): set `activeProfile = '12gb'` at the top of `config/models.psd1`.
- **At setup**: `setup.bat -Profile 12gb`.
- **Anytime**: `llm profile 12gb` (persists the choice + regenerates the config). `llm profiles` lists
  them with footprints; `llm fetch --list 12gb` previews a profile's downloads without pulling anything.

`setup` reads your GPU (`nvidia-smi`) and, if the active profile doesn't fit your VRAM, **suggests** a
better one (it never switches for you — pass `-Profile` to act on it). `llm profiles` shows the same hint.

Switching does not delete the previous profile's GGUFs — they stay in `models/`. Run `llm fetch` after
switching to pull any models the new profile is missing.
