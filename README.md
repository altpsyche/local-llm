# local-llm

A private AI stack for Windows. Models run on your NVIDIA GPU with no cloud dependencies and no data leaving the machine. Fast enough for real-time autocomplete and multi-turn coding sessions.

## What you get

| Feature | Entry point |
|---|---|
| Inference API (OpenAI-compatible) | `http://localhost:8080/v1` |
| Browser chat + RAG | Open WebUI at `:3000` |
| VS Code autocomplete | Continue.dev ghost-text completions, `Tab` to accept |
| VS Code chat | Continue.dev with `@web`, `@filesystem`, `@codebase` |
| VS Code agent | Cline: reads/writes files and runs commands |
| Terminal coding agent | aider: review the plan before any file is touched |
| Shell prompt patterns | fabric: 254 named patterns, pipe any text through them |
| Private web search | SearXNG at `:8888`, powers Continue's `@web` |
| LLM observability | Langfuse at `:3001`: traces, latency, token counts |
| Workflow automation | n8n at `:5678`: visual workflows calling the local LLM |

## Hardware

Windows 11 with an NVIDIA RTX 3000 series card or newer. Three VRAM profiles are included:

| Profile | Target cards | Model download |
|---|---|---|
| `16gb` (default) | RTX 5080, 4090, 4080 | ~38 GB |
| `12gb` | RTX 4070 Ti, 3080 Ti, 4070 | ~21 GB |
| `8gb` | RTX 3070, 4060 (unvalidated) | ~12 GB |

Setup detects your GPU and selects the best-fit profile automatically. RTX 5000 (Blackwell) requires CUDA 12.8; `install_prereqs.bat` handles version selection. On an RTX 5080 with the default profile: pp512 ~4600 t/s, tg128 ~89 t/s.

## Quick start

Git, Scoop, and PowerShell 7 are required before running these. Everything else installs automatically.

**Step 1: install prerequisites (once per machine)**

```powershell
git clone --recurse-submodules <your-remote> C:\local-llm
cd C:\local-llm
.\install_prereqs.bat
```

Installs CUDA, Python 3.12, Go, Node.js, cmake, and Docker Desktop. If Docker Desktop was just installed, log out and back in before step 2.

**Step 2: build, configure, and start**

```powershell
.\setup.bat
llm up
```

Builds the inference engine and proxy from source, downloads models, wires VS Code and terminal clients, and starts Docker services. Open a new terminal after setup so the PATH update takes effect. `llm up` starts the endpoint on `:8080` and Open WebUI on `:3000` in the background. Tail logs with `llm logs`.

Both scripts are safe to re-run if something fails partway through.

Flags for `setup.bat`: `-Profile 12gb` (smaller model set), `-SkipModels` (skip downloads), `-Launch` (start the stack when setup finishes).

## Docs

[DAY-IN-THE-LIFE](docs/DAY-IN-THE-LIFE.md): hands-on walkthrough of every feature structured as a working session. Start here after setup.

[SETUP](docs/SETUP.md): prerequisites, two-step install flow, build steps, verification.

[USAGE](docs/USAGE.md): full command reference, API details, client configuration, Docker services, customization.

[MANUAL-INSTALL.md](docs/MANUAL-INSTALL.md): step-by-step for advanced users with exact cmake flags, venv creation, and Docker wiring.

[TUNING](docs/TUNING.md): per-model launch flags, VRAM sizing, performance checks, updating the engine.

[FALLBACKS](docs/FALLBACKS.md): alternatives and workarounds for failed builds or installs.
