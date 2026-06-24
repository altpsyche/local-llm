# local-llm

Self-contained, reproducible local LLM stack for Windows 11 with an NVIDIA RTX 5080 (16GB, Blackwell sm_120). One tuned inference engine (llama.cpp on CUDA 12.8) sits behind a hot-swap proxy (llama-swap) that exposes a single OpenAI-compatible endpoint at `http://localhost:8080/v1` for your IDE, terminal tools, RAG UI, and scripts.

Verified on the target box: 14B Q4 at roughly 4300 t/s prefill and 86 t/s generation on the fast sm_120 MMQ path, with chat, autocomplete, and embeddings all served through the one endpoint.

## Quick start
```powershell
git clone --recurse-submodules <your-remote> C:\local-llm
cd C:\local-llm
.\setup.bat
llm up
```
`setup.bat` is a one-shot, idempotent installer: it sets up prereqs (CUDA 12.8, Python, Go), builds the engine and proxy, downloads the models, wires the clients, and puts the `llm` command on PATH. Re-run it any time. Use `setup.bat -SkipModels` to skip the model downloads, or `setup.bat -Launch` to start the stack when it finishes. You provide Git, scoop, and PowerShell 7.

After setup, start the stack each session from a new terminal with `llm up` (endpoint on :8080 plus Open WebUI on :3000). Other commands include `llm serve`, `llm aider`, `llm chat coder "..."`, `llm profiles`, `llm bench`, and `llm help`.

## Choosing a model set for your VRAM
Every model is defined once in `config/models.psd1`, grouped into VRAM profiles. The default is `16gb`. On a smaller card, pick the `12gb` profile before setup with `setup.bat -Profile 12gb`, or switch any time with `llm profile 12gb`. Setup reads your GPU and suggests a profile when the active one will not fit.

The downloader and the runtime config both read `config/models.psd1`, so a single edit changes both. `config/llama-swap.yaml` is generated from it (and regenerated on every `llm serve`), so you never edit that file by hand. See [docs/USAGE.md](docs/USAGE.md) for switching profiles and adding new ones.

## Build with CUDA 12.8, never 13.x
Blackwell (sm_120) MMQ kernels built against CUDA 13.x crash or fall back to cuBLAS, roughly 5 to 6 times slower on prefill. The llama.cpp submodule is pinned to a known-good commit. See [docs/SETUP.md](docs/SETUP.md) and [docs/TUNING.md](docs/TUNING.md).

## Docs
[SETUP](docs/SETUP.md) covers install and build.

[USAGE](docs/USAGE.md) covers daily use, pointing each tool at the endpoint, and model profiles.

[TUNING](docs/TUNING.md) covers launch flags, VRAM math, perf checks, and submodule bumps.

[FALLBACKS](docs/FALLBACKS.md) covers what to do when any layer fails.
