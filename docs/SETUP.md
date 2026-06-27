# SETUP

## Hardware

The verified configuration is Windows 11 with an NVIDIA RTX 5080 (16 GB VRAM, Blackwell sm_120), a Ryzen 9 7950X3D, and 64 GB of system RAM. RTX 4000-series (Ada Lovelace) and RTX 3000-series (Ampere) cards are supported with the same scripts; setup detects the GPU and adapts the build automatically. Profiles for 16 GB, 12 GB, and 8 GB VRAM are included.

> **Advanced users:** [MANUAL-INSTALL.md](MANUAL-INSTALL.md) covers every step in detail: exact cmake commands, Go builds, venv creation, and client wiring. Use it when you want full control or need to debug a partial install.

## Prerequisites

Three tools you must provide manually (`install_prereqs.bat` cannot bootstrap these):

| Tool | Notes |
|---|---|
| **Git** | Required to clone the repo |
| **Scoop** | Package manager used to install Python 3.12 and Go (`irm get.scoop.sh \| iex`) |
| **PowerShell 7** | `winget install Microsoft.PowerShell` |

`install_prereqs.bat` handles everything else: Node.js, uv, Go, Python 3.12, CUDA Toolkit, cmake, and Docker Desktop. For exact install commands, version requirements, and troubleshooting, see [MANUAL-INSTALL.md § 1 Prerequisites](MANUAL-INSTALL.md#1-prerequisites).

## Installing

On a fresh machine, installation is two commands with a possible logout in between:

**Step 1: install all prerequisites:**
```powershell
.\install_prereqs.bat
```
Installs Node.js, uv, Go, Python 3.12, CUDA Toolkit, cmake, and Docker Desktop. If Docker Desktop was just installed, log out of Windows and back in before continuing. If Docker was already installed, proceed directly to step 2.

**Step 2: build, configure, and start everything:**
```powershell
git clone --recurse-submodules <your-remote> C:\local-llm
cd C:\local-llm
.\setup.bat
```
Fully automated from here. Builds the inference engine, downloads models, wires clients, and starts Docker services automatically.

`setup.bat` is idempotent. If something fails partway through, fix the issue and re-run it; completed steps are skipped.

- `setup.bat -SkipModels` builds and configures everything but skips the downloads
- `setup.bat -Launch` starts the stack automatically when setup finishes
- `setup.bat -Profile 12gb` selects the smaller model profile before downloading anything

After setup, open a new terminal to pick up the PATH change, then run `llm up`.

## What setup does, step by step

`setup.bat` calls `scripts\setup.ps1`, which runs these steps in order. You can run any of them individually if you need to redo a specific part:

0. `.\scripts\diagnose.ps1` prints a machine summary (GPU, VRAM, RAM, CUDA, NUMA topology, mlock privilege, active profile, model files) before anything is installed. Run `llm diagnose` at any time to see the same report.
1. `git submodule update --init --recursive` fetches the llama.cpp and llama-swap source trees.
2. `.\scripts\build-llama.ps1` compiles llama.cpp against CUDA 12.8 and writes the binaries to `bin/`. Skips if the binary already exists; pass `-Force` to rebuild from scratch. Before replacing an existing binary, the script backs it up as `bin/llama-server.exe.bak`. If a rebuild leaves things broken, restore it with `Move-Item bin\llama-server.exe.bak bin\llama-server.exe`.
3. `.\scripts\build-llama-swap.ps1` compiles the model-swap proxy.
4. Python virtual environments are created in `tools/venv-aider`, `tools/venv-webui`, `tools/venv-litellm`, and `tools/venv-eval` and their dependencies are installed. These are kept separate on purpose. Their dependency pins conflict and can't be merged into one environment.
5. `.\scripts\gen-llama-swap.ps1` generates `config/llama-swap.yaml` from `config/models.psd1`.
6. `.\scripts\fetch-models.ps1` downloads GGUF model files for the active profile.
7. `.\scripts\setup-clients.ps1` symlinks `config/continue/config.yaml` to `~/.continue/config.yaml` and checks VS Code extension status.
8. `.\scripts\setup-fabric.ps1` installs the fabric CLI and configures it to use the local endpoint.
9. `.\scripts\install-cli.ps1` puts the `llm` command on PATH.
10. **Memory lock:** reads `config/user.psd1` to check if `mlockBig = $true` is set. If it is, runs `scripts\grant-mlock.ps1` automatically (UAC prompt; one-time per machine). If `mlockBig` is not set but ≥ 32 GB RAM is free, prints a tip on how to enable it. Otherwise reports why it was skipped. Open a new terminal after setup completes for the privilege to take effect.
11. `.\scripts\setup-docker.ps1` pulls and starts the Docker services stack (Langfuse, SearXNG, n8n). Runs automatically if Docker Desktop is installed; skipped gracefully if not.

To pin llama.cpp to a specific commit or bump to a newer version, see [MANUAL-INSTALL.md § 4](MANUAL-INSTALL.md#4-build-llamacpp) and [TUNING.md](TUNING.md#bumping-the-llamacpp-submodule).

**Docker services** (Langfuse, SearXNG, n8n) extend the stack with observability, private web search, and automation:

| Service | Port | What it does | Why you'd want it |
|---|---|---|---|
| **Langfuse** | 3001 | LLM observability: every prompt, completion, latency, and token count in a dashboard | Debug unexpected model output; compare quant levels; trace exactly what aider/Cline sends |
| **SearXNG** | 8888 | Self-hosted meta-search (queries Google/Bing without sending your searches to the cloud) | Powers Continue.dev `@web`: type `@web <query>` in Continue chat and the model gets live search results |
| **n8n** | 5678 | Visual workflow automation (like Zapier, local): chains LLM calls, webhooks, and APIs | Automate tasks without scripts: summarize PRs on open, generate commit messages, run daily digests |

None are required for core inference. They start automatically at the end of `setup.bat` if Docker Desktop is installed.

### Installing Docker services

Docker services start automatically at the end of `setup.bat`. No separate step needed.

> **Before `setup.bat` finishes:** Docker Desktop → Settings → General → uncheck
> **"Use containerd for pulling and storing images"** → Apply & Restart.
> If this setting is on, SearXNG fails with `exec /bin/sh: exec format error`. Only needs to be changed once.

Verify the containers started:
```powershell
llm services status
# Expected: four rows, all "Up": compose-langfuse-postgres-1, compose-langfuse-1, compose-searxng-1, compose-n8n-1
```

URLs after first run:
- Langfuse: http://localhost:3001 (login: `admin@local.dev` / `admin123`)
- SearXNG: http://localhost:8888
- n8n: http://localhost:5678

Day-to-day management: `llm services start|stop|status|logs`.

For a detailed walkthrough of what `setup-docker.ps1` does internally, including troubleshooting, see [MANUAL-INSTALL.md § Docker services](MANUAL-INSTALL.md#12-docker-services).

## Verifying the install

```powershell
llm serve                 # start the inference endpoint (default port 8080)
llm models                # should list: planner, coder, chat, fim, embed
llm bench                 # performance check (see expected numbers below)
llm chat coder "hi"       # end-to-end sanity check
llm diagnose              # re-run hardware summary at any time; flags any unresolved issues
```

**Memory lock** is handled automatically during setup (step 10). If you enable `mlockBig = $true` in `config/user.psd1` after setup, run `llm mlock` to grant `SeLockMemoryPrivilege` and restart your terminal.

On an RTX 5080 with the 14B Q4 coder model, expected numbers are **pp512 ≈ 4600 t/s, tg128 ≈ 89 t/s**. These confirm the engine is on the fast Blackwell hardware path. Ada and Ampere cards will show lower numbers; what matters is that prefill is not disproportionately slow relative to generation (see [TUNING.md](TUNING.md#verifying-the-fast-path)).

If prefill throughput is around 1000 t/s rather than 4000+, the build is using a slower fallback, most likely because it was compiled against CUDA 13.x or has a stale build cache. Fix this by running `scripts\build-llama.ps1 -Force`, which wipes the build directory and recompiles from scratch. Make sure CUDA 12.8 is the active toolkit when you do.
