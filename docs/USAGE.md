# USAGE

This document covers day-to-day use: starting and stopping the server, what each client does and how to configure it, and how to manage model profiles. For installation, see [SETUP.md](SETUP.md). For performance tuning and updating the engine, see [TUNING.md](TUNING.md).

## One-time client setup

```powershell
.\scripts\setup-clients.ps1
```

Run this once per machine. It links the VS Code Continue config and the aider config from the repo into your home directory, so both tools work without any in-app configuration. Open WebUI is wired automatically when you start the stack. If you don't have symlink privileges, the script copies the files instead; re-run it after editing the repo configs to sync the copies.

## The `llm` command

`setup.bat` puts `llm` on your PATH. Open a terminal and these commands are available:

```
llm diagnose             GPU, VRAM, CUDA, and model file health check
llm up                   start the endpoint + Open WebUI (ports from defaults, default 8080/3000)
llm serve                start the endpoint only (default port 8080), without the web UI
llm stop                 stop the endpoint and free VRAM
llm aider [args]         run aider in architect mode in the current folder
llm webui                start Open WebUI only (default port 3000)
llm chat <model> <text>  send a one-shot message, e.g.  llm chat coder "write fizzbuzz"
llm models               list the available model names
llm bench [gguf]         run a throughput benchmark
llm profiles             list VRAM profiles and which one is active
llm profile <name>       switch profiles (e.g. llm profile 12gb) and regenerate the config
llm fetch [--list] [p]   download models for a profile; --list previews without downloading
llm verify-urls [<profile>]  check all HuggingFace download URLs are reachable (needs network)
llm gen                  regenerate config/llama-swap.yaml from config/models.psd1
```

If `llm` isn't found after setup, run `scripts\install-cli.ps1` and open a fresh terminal.

## Starting the stack each session

```powershell
llm up        # endpoint on configured port (default 8080) + Open WebUI (default 3000)
```

Or, if you only need the API for IDE and terminal tools:

```powershell
llm serve     # inference endpoint at http://localhost:<port>/v1  (default: 8080)
```

The server loads a model into VRAM when it first receives a request, and unloads it when it's been idle for a while. The exception is `fim` (autocomplete) and `embed` (embeddings), which are pinned in VRAM and never unloaded. Only one large model (`planner`, `coder`, or `chat`) is resident at a time; switching between them takes a few seconds.

To start automatically at login, put a shortcut to `up.ps1` in `shell:startup`, or create a Task Scheduler task set to "At log on" running `pwsh -File C:\local-llm\scripts\up.ps1`.

## Available models (16gb profile)

| Name | Role | Backing model |
|---|---|---|
| `planner` | heavy reasoning and architecture | Qwen3-30B-A3B Q4 |
| `coder` | coding chat and agentic edits | Qwen2.5-Coder-14B Q4_K_M |
| `chat` | general conversation | Qwen3-14B Q4_K_M |
| `fim` | autocomplete (pinned) | Qwen-Coder-3B Q8_0 |
| `embed` | RAG embeddings (pinned) | bge-m3 Q8 |

Every model's GGUF file, HuggingFace source, context size, and launch flags are defined once in [config/models.psd1](../config/models.psd1). The downloader and the runtime config both read from it. Clients reference the role names above (`coder`, `planner`, etc.), so swapping the backing model for a role never requires touching any client configuration.

The `12gb` profile uses smaller variants (about 21 GB on disk instead of 38 GB). The `8gb` profile targets cards like the RTX 3070 and 4060 and is marked unvalidated — it ships with the repo but has not been tested on physical hardware yet. Switch with `llm profile 12gb` or `llm profile 8gb`, or pass `-Profile` to `setup.bat` before the first model download.

## Calling the API directly

The endpoint speaks the OpenAI chat completions API, so any HTTP client works:

```powershell
curl http://localhost:8080/v1/chat/completions -H "Content-Type: application/json" -d '{
  "model": "coder", "messages": [{"role":"user","content":"write a fizzbuzz in rust"}] }'
```

The port defaults to `8080`. To change it, set `port` in the `defaults` block of `config/models.psd1` or create a `config/user.psd1` override (see [TUNING.md](TUNING.md#tunable-defaults-and-personal-overrides)).

The `chat` and `planner` models (Qwen3) reason in a hidden scratchpad before responding. This can consume your entire `max_tokens` budget if you set it too low, leaving the visible reply empty. Give these models at least 512 tokens, or append `/no_think` to your prompt to skip the reasoning step and get a direct answer. GUI clients like Open WebUI handle this automatically, so it only affects raw API calls with small token limits.

## VS Code — Continue.dev (autocomplete and chat)

Continue.dev provides inline autocomplete and a chat panel inside VS Code. `setup-clients.ps1` links the repo's config into `~/.continue/config.yaml`, so all models are wired with no in-editor setup needed.

To get started, run `.\scripts\setup-clients.ps1` once, install the **Continue** extension from the VS Code Marketplace, then start the endpoint with `llm serve` or `llm up`. Open the Continue panel with the sidebar icon or `Ctrl+L` and the `coder` and `planner` models should appear immediately.

**How models map to Continue roles:**

| Continue role | Model | Purpose |
|---|---|---|
| Chat, edit, apply | `coder` (Qwen2.5-Coder-14B) | default coding chat and inline edits |
| Chat, edit | `planner` (Qwen3-30B-A3B) | architecture discussion and heavy reasoning |
| Autocomplete | `fim` (Qwen-Coder-3B, pinned) | as-you-type ghost text completions |
| Embed | `embed` (bge-m3, pinned) | `@codebase` and `@docs` RAG indexing |

`Ctrl+L` opens a new chat with any selected code attached as context. `Ctrl+I` opens an inline edit on the selected lines and shows a diff for you to accept or reject. Autocomplete fires as ghost text; `Tab` accepts it. Use the model dropdown at the bottom of the chat panel to switch between `coder` (everyday edits) and `planner` (design and architecture questions).

Context is 16384 tokens for `coder` and `planner`. Large `@codebase` queries get truncated to fit; use `@file` when you need to be precise about what's included. The first message to a large model is slower while it loads into VRAM. `fim` and `embed` stay pinned so autocomplete and RAG never trigger a reload.

If you used a copied config rather than a symlink and later edited the repo's config, re-run `setup-clients.ps1` after deleting the copy, or edit `~/.continue/config.yaml` directly.

## VS Code — Cline (agentic)

Cline is a more autonomous agent that reads and writes files, runs commands, and works across many turns. It's not auto-wired; configure it once in its settings panel.

Install the **Cline** extension, start the endpoint, then open Cline settings and set the API provider to `OpenAI Compatible`:

| Field | Value |
|---|---|
| Base URL | `http://localhost:8080/v1` (replace `8080` if you changed `defaults.port`) |
| API Key | `sk-local` (any non-empty string; the server ignores it) |
| Model ID | `coder` |

Set the context window to `16384` to match the server's limit. Leaving it higher causes Cline to send requests the server can't handle. Leave image support off; these models are not multimodal.

To use separate models for planning and editing, enable **Use different models for Plan and Act** in Cline settings and set the Plan Model ID to `planner` and the Act Model ID to `coder`. Switching between modes evicts the other model from VRAM, so there is a brief load pause.

Cline burns through its 16k context window quickly on multi-step tasks. Keep tasks focused and start a new task when the history grows large. For tasks that need deeper reasoning, set the Model ID to `planner`; it's slower but handles complex planning better. Switching models evicts the other from VRAM.

## Terminal — aider (plan and edit separately)

Aider is the one client here with a genuine planning-versus-editing split. `planner` (Qwen3-30B) drafts the change, and `coder` (Qwen2.5-Coder-14B) turns that draft into file edits. You review the plan before any edit lands.

Run `.\scripts\setup-clients.ps1` to link the aider config (`config/aider/.aider.conf.yml`) into your home directory. aider picks it up automatically from there. Then start the endpoint and run aider from any project:

```powershell
cd <your-project>
llm aider
```

The config sets `architect: true`, which sends your request to `planner` first. It writes a prose description of what needs to change, then `coder` turns that into a diff. With `auto-accept-architect: false`, you see the plan and press Enter to apply it, or refine it before anything is written. Each turn triggers a VRAM swap between `planner` and `coder`, which takes a few seconds.

Useful in-session commands:

| Command | What it does |
|---|---|
| `/add <file>` | add a file to the editable context |
| `/read <file>` | add a file as read-only reference |
| `/ask <question>` | ask a question without triggering any edits |
| `/diff` | show pending changes |
| `/undo` | revert aider's last committed edit |
| `/drop` | remove files from context when it gets large |

aider commits each accepted edit to git automatically. Work on a branch so `/undo` can roll back cleanly. Both models use a 16k context window; on large repos, prefer `/read` over `/add` for files you're only referencing, and use `/drop` to remove files you no longer need. The `openai/` prefix in the config (`openai/planner`, `openai/coder`) is required for aider to route through a local OpenAI-compatible endpoint and is already set correctly.

## Browser chat and RAG — Open WebUI

`llm up` starts Open WebUI on port 3000, pre-wired to the local inference endpoint and embedding model. There's no manual admin setup. If you want it without the inference stack, use `llm webui`.

Open WebUI uses the `embed` model for document search automatically. Add documents through the workspace panel; they're indexed locally and available in any chat via the RAG interface. You can create model presets in Workspace → Models, for example a "Planner" preset with low temperature for precise answers, or a "Chat" preset for general conversation.

## Managing model profiles

`config/models.psd1` defines all models grouped into profiles. The `activeProfile` key at the top selects which one is used.

```powershell
llm profiles             # list all profiles with VRAM footprints and current selection
llm profile 12gb         # switch profiles and regenerate the server config
llm fetch --list 12gb    # preview what the 12gb profile would download, without downloading
llm fetch                # download any models the current profile is missing
```

Switching profiles does not delete models from previous profiles; they stay in `models/`. Run `llm fetch` after switching to pull any files the new profile needs that aren't already there.

To add or change a model, edit its entry in `config/models.psd1` (setting `repo`, `path`, `gguf`, `ctx`, and any optional flags), then run `llm fetch` to download it and `llm serve` to pick it up. The server config (`config/llama-swap.yaml`) is generated automatically on each launch and should never be edited by hand.

To add a new profile for a different VRAM tier, add a new key under `profiles` in the PSD1 file and switch to it with `llm profile <name>`.
