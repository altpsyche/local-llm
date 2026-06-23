# local-llm

Self-contained, reproducible local-LLM stack for **Windows 11 + NVIDIA RTX 5080 (16GB, Blackwell sm_120)**.
One tuned inference engine (`llama.cpp`, CUDA 12.8) behind a hot-swap proxy (`llama-swap`) exposing a single
**OpenAI-compatible endpoint** at `http://localhost:8080/v1` for your IDE, terminal tools, RAG UI, and scripts.

## Quick start
```powershell
git clone --recurse-submodules <your-remote> C:\local-llm
cd C:\local-llm
# prereqs: CUDA Toolkit 12.8, then:
scoop install python312 go
.\scripts\bootstrap.ps1     # submodules -> build -> venv -> fetch models
.\scripts\start.ps1         # launch the endpoint on :8080
```

## Layout
| Path | Tracked? | What |
|---|---|---|
| `external/` | submodules | `llama.cpp` (CUDA-12.8 build) + `llama-swap` (Go proxy) |
| `config/` | ✅ committed | `llama-swap.yaml`, Continue `config.yaml`, aider `.aider.conf.yml` — your tuning |
| `models/models.manifest` | ✅ committed | HF repo + filename per model |
| `models/*.gguf` | ✗ gitignored | fetched by `scripts/fetch-models.ps1` |
| `tools/requirements.txt` | ✅ committed | Open WebUI + aider (pip) |
| `tools/venv312/` | ✗ gitignored | Python 3.12 venv |
| `bin/` | ✗ gitignored | built `llama-server.exe`, `llama-swap.exe` |
| `scripts/` | ✅ committed | bootstrap / build / fetch / start |
| `docs/` | ✅ committed | SETUP · USAGE · TUNING · FALLBACKS |

## ⚠️ Build with CUDA 12.8 — never 13.x
Blackwell (`sm_120`) MMQ kernels built against CUDA 13.x crash or fall back to cuBLAS (~5–6× slower prefill).
The `llama.cpp` submodule is pinned to a known-good commit. See [docs/SETUP.md](docs/SETUP.md) and [docs/TUNING.md](docs/TUNING.md).

## Docs
- [SETUP](docs/SETUP.md) — install & build
- [USAGE](docs/USAGE.md) — daily use, point each tool, per-role models
- [TUNING](docs/TUNING.md) — flags, VRAM math, perf checks, submodule bumps
- [FALLBACKS](docs/FALLBACKS.md) — what to do when any layer fails
