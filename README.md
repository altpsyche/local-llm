# local-llm

Self-contained, reproducible local-LLM stack for **Windows 11 + NVIDIA RTX 5080 (16GB, Blackwell sm_120)**.
One tuned inference engine (`llama.cpp`, CUDA 12.8) behind a hot-swap proxy (`llama-swap`) exposing a single
**OpenAI-compatible endpoint** at `http://localhost:8080/v1` for your IDE, terminal tools, RAG UI, and scripts.

Verified on the target box: 14B Q4 at **~4300 t/s prefill / ~86 t/s generation** (fast sm_120 MMQ path), with chat, autocomplete, and embeddings all serving through the one endpoint.

## Quick start
```powershell
git clone --recurse-submodules <your-remote> C:\local-llm
cd C:\local-llm
.\setup.bat            # ONE-SHOT: prereqs (CUDA 12.8, Python, Go) -> build -> models -> wire clients + 'llm' cmd
llm up                 # then, each session (new terminal): endpoint :8080 + Open WebUI :3000
```
`setup.bat` also installs the **`llm`** command on PATH — `llm up`, `llm aider`, `llm chat coder "..."`,
`llm bench`, `llm help`. It's idempotent — re-run anytime. `setup.bat -SkipModels` skips the ~38GB
downloads; `setup.bat -Launch` starts the stack. (Prereqs: Git, scoop, PowerShell 7.)

## Layout
| Path | Tracked? | What |
|---|---|---|
| `external/` | submodules | `llama.cpp` (CUDA-12.8 build) + `llama-swap` (Go proxy) |
| `config/models.psd1` | ✅ committed | **single source of truth** — every model + VRAM profile |
| `config/` (other) | ✅ committed | Continue `config.yaml`, aider `.aider.conf.yml` — your tuning |
| `config/llama-swap.yaml` | ✗ gitignored | **generated** from `models.psd1` by `gen-llama-swap.ps1` |
| `models/*.gguf` | ✗ gitignored | fetched by `scripts/fetch-models.ps1` (per the active profile) |
| `tools/*-requirements.txt` | ✅ committed | Open WebUI + aider pins (separate — they conflict) |
| `tools/venv-webui,-aider/` | ✗ gitignored | per-tool Python 3.12 venvs |
| `bin/` | ✗ gitignored | built `llama-server.exe`, `llama-swap.exe`, CUDA DLLs |
| `setup.bat` | ✅ committed | one-shot post-clone setup (→ `scripts/setup.ps1`) |
| `scripts/` | ✅ committed | setup · bootstrap · build · fetch · start · setup-clients · install-cli · llm · up |
| `docs/` | ✅ committed | SETUP · USAGE · TUNING · FALLBACKS |

## ⚠️ Build with CUDA 12.8 — never 13.x
Blackwell (`sm_120`) MMQ kernels built against CUDA 13.x crash or fall back to cuBLAS (~5–6× slower prefill).
The `llama.cpp` submodule is pinned to a known-good commit. See [docs/SETUP.md](docs/SETUP.md) and [docs/TUNING.md](docs/TUNING.md).

## Docs
- [SETUP](docs/SETUP.md) — install & build
- [USAGE](docs/USAGE.md) — daily use, point each tool, per-role models
- [TUNING](docs/TUNING.md) — flags, VRAM math, perf checks, submodule bumps
- [FALLBACKS](docs/FALLBACKS.md) — what to do when any layer fails
