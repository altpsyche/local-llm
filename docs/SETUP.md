# SETUP

## Hardware

The verified configuration is Windows 11 with an NVIDIA RTX 5080 (16 GB VRAM, Blackwell sm_120), a Ryzen 9 7950X3D, and 64 GB of system RAM. RTX 4000-series (Ada Lovelace) and RTX 3000-series (Ampere) cards are supported with the same scripts; setup detects the GPU and adapts the build automatically. Profiles for 16 GB, 12 GB, and 8 GB VRAM are included.

## Prerequisites

`setup.bat` installs these automatically, so you normally don't need to handle them by hand. They're listed here in case you're troubleshooting a partial build or want to understand what's being installed.

| Tool | Install command |
|---|---|
| **CUDA Toolkit** | Auto-detected. Blackwell (RTX 5000): requires 12.8 exactly (`winget install Nvidia.CUDA --version 12.8`). Ada (RTX 4000) / Ampere (RTX 3000): any CUDA 12.x. |
| Python 3.12 | `scoop install python312` |
| Go | `scoop install go` |
| Node.js | `winget install OpenJS.NodeJS` — for Continue MCP servers (`@fetch`, `@filesystem`, `@github`) |
| uv | `winget install astral-sh.uv` — for `mcp-server-fetch` via `uvx` |
| **Docker Desktop** | `winget install Docker.DockerDesktop` — optional; required for Langfuse, SearXNG, n8n (see [USAGE.md § Docker services](USAGE.md#docker-services-langfuse--searxng--n8n)) |
| Git, VS 2022 with C++ x64 | Install manually. `setup.bat` checks for VS2022 with the 'Desktop development with C++' workload on start and throws a clear error with install instructions if missing: `winget install Microsoft.VisualStudio.2022.Community`. cmake 3.x is located automatically (via VS or PATH) and installed via winget if absent. |

You need to supply Git, Scoop, and PowerShell 7 yourself before running setup. Those are the only tools setup can't install.

### CUDA and the MSVC compiler version

Some CUDA versions reject the newest VS 2022 toolset with an `unsupported Microsoft Visual Studio version` error during the build. If this happens, either add `-DCMAKE_CUDA_FLAGS="-allow-unsupported-compiler"` to the cmake line in `scripts/build-llama.ps1`, or install an MSVC toolset that matches your CUDA version through the VS Installer (v14.4x for CUDA 12.8).

## Installing

```powershell
git clone --recurse-submodules <your-remote> C:\local-llm
cd C:\local-llm
.\setup.bat
```

`setup.bat` takes the repository from a fresh clone to a fully working stack. In order, it installs prerequisites, builds the inference engine and proxy from source, creates isolated Python environments for the web UI and terminal tools, downloads the model files, wires the VS Code and terminal clients, and puts the `llm` command on your PATH.

The script is idempotent. If something fails partway through, fix the issue and re-run it; completed steps are skipped.

- `setup.bat -SkipModels` builds and configures everything but skips the downloads
- `setup.bat -Launch` starts the stack automatically when setup finishes
- `setup.bat -Profile 12gb` selects the smaller model profile before downloading anything

After setup, open a new terminal to pick up the PATH change, then run `llm up`.

## What setup does, step by step

`setup.bat` calls `scripts\setup.ps1`, which runs these steps in order. You can run any of them individually if you need to redo a specific part:

0. `.\scripts\diagnose.ps1` prints a machine summary (GPU, VRAM, CUDA, active profile, model files) before anything is installed. Run `llm diagnose` at any time to see the same report.
1. `git submodule update --init --recursive` fetches the llama.cpp and llama-swap source trees.
2. `.\scripts\build-llama.ps1` compiles llama.cpp against CUDA 12.8 and writes the binaries to `bin/`. Skips if the binary already exists; pass `-Force` to rebuild from scratch. Before replacing an existing binary, the script backs it up as `bin/llama-server.exe.bak`. If a rebuild leaves things broken, restore it with `Move-Item bin\llama-server.exe.bak bin\llama-server.exe`.
3. `.\scripts\build-llama-swap.ps1` compiles the model-swap proxy.
4. Python virtual environments are created in `tools/venv-aider`, `tools/venv-webui`, `tools/venv-litellm`, and `tools/venv-eval` and their dependencies are installed. These are kept separate on purpose — their dependency pins conflict and can't be merged into one environment.
5. `.\scripts\gen-llama-swap.ps1` generates `config/llama-swap.yaml` from `config/models.psd1`.
6. `.\scripts\fetch-models.ps1` downloads GGUF model files for the active profile.
7. `.\scripts\setup-clients.ps1` symlinks `config/continue/config.yaml` to `~/.continue/config.yaml` and checks VS Code extension status.
8. `.\scripts\setup-fabric.ps1` installs the fabric CLI and configures it to use the local endpoint.
9. `.\scripts\install-cli.ps1` puts the `llm` command on PATH.

**Optional — Docker services** (Langfuse, SearXNG, n8n) are not part of `setup.bat` because Docker Desktop requires a logout/restart mid-install. These three services extend the stack with observability, private web search, and automation:

| Service | Port | What it does | Why you'd want it |
|---|---|---|---|
| **Langfuse** | 3001 | LLM observability — every prompt, completion, latency, and token count in a dashboard | Debug unexpected model output; compare quant levels; trace exactly what aider/Cline sends |
| **SearXNG** | 8888 | Self-hosted meta-search (queries Google/Bing without sending your searches to the cloud) | Powers Continue.dev `@web` — type `@web <query>` in Continue chat and the model gets live search results |
| **n8n** | 5678 | Visual workflow automation (like Zapier, local) — chains LLM calls, webhooks, and APIs | Automate tasks without scripts: summarize PRs on open, generate commit messages, run daily digests |

None are required for core inference. Run separately after `setup.bat`.

### Installing Docker services

The setup runs in two passes if Docker Desktop isn't already installed:

**Pass 1 — installs Docker Desktop:**
```powershell
.\scripts\setup-docker.ps1
# Installs Docker Desktop via winget, then exits with:
#   ACTION REQUIRED: Log out and back in, then re-run: .\scripts\setup-docker.ps1
```
Log out of Windows and back in. This is required because Docker Desktop adds your user to the `docker-users` Windows group, and group membership changes only take effect at login.

**Pass 2 — pulls images and starts services:**
```powershell
.\scripts\setup-docker.ps1
```

What this does, in order:
1. Checks Docker is on PATH; adds it if Docker Desktop is installed but this session predates it
2. Waits up to 90 seconds for the Docker daemon; starts Docker Desktop automatically if it's not running
3. Reads port config from `config/models.psd1` (overridable via `config/user.psd1`)
4. Writes `tools/compose/.env` with `REPO_PATH`, `LANGFUSE_PORT`, `SEARXNG_PORT`, `N8N_PORT`
5. Creates `tools/langfuse-data/` and `tools/n8n-data/` (gitignored — this is where persistent data lives)
6. Writes `config/searxng/settings.yml` if it doesn't exist
7. Pulls all four images from Docker Hub (~3 GB total on first run):
   - `postgres:16-alpine` (~80 MB) — database for Langfuse
   - `langfuse/langfuse:3` (~200 MB) — observability UI
   - `searxng/searxng:<date>` (~100 MB) — search engine
   - `n8nio/n8n:latest` (~2.5 GB) — workflow automation
8. Starts all four containers with `docker compose up -d`

Expected output on success:
```
Checking Docker daemon...
  Docker ready.
  Ports: Langfuse=3001  SearXNG=8888  n8n=5678
Pulling images (first run may take a few minutes)...
 Image postgres:16-alpine Pulled
 Image langfuse/langfuse:3 Pulled
 Image searxng/searxng:... Pulled
 Image n8nio/n8n:latest Pulled
Starting services...
 Container compose-langfuse-postgres-1 Started
 Container compose-langfuse-postgres-1 Healthy
 Container compose-langfuse-1 Started
 Container compose-searxng-1 Started
 Container compose-n8n-1 Started

Services running:
  Langfuse:  http://localhost:3001  (login: admin@local.dev / admin123)
  SearXNG:   http://localhost:8888
  n8n:       http://localhost:5678
```

Verify the containers are all up:
```powershell
llm services status
# Expected: four rows, all "Up" — compose-langfuse-postgres-1, compose-langfuse-1, compose-searxng-1, compose-n8n-1
```

Day-to-day management: `llm services start|stop|status|logs`. The full `setup-docker.ps1` only needs to run once; use `llm services start` afterward.

### Troubleshooting Docker setup

| Symptom | Cause | Fix |
|---------|-------|-----|
| Script exits with "ACTION REQUIRED: Log out and back in" | Docker Desktop just installed — group change needs login | Log out of Windows, log back in, re-run |
| `docker info` returns 500 Internal Server Error | WSL2 backend crashed or still initializing after restart | Wait 60 s for Docker Desktop to fully start; or Restart Docker Desktop from system tray |
| `exec /bin/sh: exec format error` on any container | Image layers corrupted by an interrupted download | `docker system prune -af` then re-run `.\scripts\setup-docker.ps1` |
| `langfuse-postgres unhealthy` / `dependency failed to start` | Postgres container failed — almost always the exec format error above | Same fix: `docker system prune -af`, re-run |
| Port conflict — address already in use | Another process using 3001, 8888, or 5678 | Set `langfusePort`, `searxngPort`, or `n8nPort` in `config/user.psd1`, re-run `.\scripts\setup-docker.ps1` |
| `exec /bin/sh: exec format error` only on SearXNG, other images work | Docker Desktop "containerd snapshotter" mishandles SearXNG's merged `/bin→usr/bin` filesystem | Docker Desktop → Settings → General → uncheck **"Use containerd for pulling and storing images"** → Apply & Restart → re-run setup |
| `docker: command not found` after Docker Desktop install | PATH not refreshed in this session | Open a new terminal, or add `C:\Program Files\Docker\Docker\resources\bin` to PATH manually |
| Daemon timeout (90 s) | Docker Desktop not installed, or very slow to start | Launch Docker Desktop manually from Start menu, wait for whale icon, re-run |

Running `.\scripts\bootstrap.ps1` directly does steps 1 through 6 without the client wiring. Add `-SkipModels` to skip the downloads.

## Pinning the llama.cpp version

The repository records the exact llama.cpp commit that is verified to work on Blackwell. To pin a different commit:

```powershell
cd external\llama.cpp
git checkout <commit-or-tag>
cd ..\..
git add external/llama.cpp
git commit -m "pin llama.cpp to <commit>"
```

See [TUNING.md](TUNING.md#bumping-the-llamacpp-submodule) for bumping to a newer version and re-verifying performance afterward.

## Verifying the install

```powershell
llm serve                 # start the inference endpoint (default port 8080)
llm models                # should list: planner, coder, chat, fim, embed
llm bench                 # performance check (see expected numbers below)
llm chat coder "hi"       # end-to-end sanity check
```

On an RTX 5080 with the 14B Q4 coder model, expected numbers are **pp512 ≈ 4600 t/s, tg128 ≈ 89 t/s**. These confirm the engine is on the fast Blackwell hardware path. Ada and Ampere cards will show lower numbers — what matters is that prefill is not disproportionately slow relative to generation (see [TUNING.md](TUNING.md#verifying-the-fast-path)).

If prefill throughput is around 1000 t/s rather than 4000+, the build is using a slower fallback, most likely because it was compiled against CUDA 13.x or has a stale build cache. Fix this by running `scripts\build-llama.ps1 -Force`, which wipes the build directory and recompiles from scratch. Make sure CUDA 12.8 is the active toolkit when you do.
