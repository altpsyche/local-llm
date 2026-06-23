# FALLBACKS

A working alternative at every layer. All clients point at one OpenAI endpoint, so swapping a layer
rarely touches the others.

| Layer | Primary | Fallback 1 | Fallback 2 (zero-build) |
|---|---|---|---|
| Engine | llama.cpp submodule, CUDA 12.8 | official prebuilt CUDA-12.4 zip | **Ollama** |
| Proxy | llama-swap (go build) | llama-swap release **binary** | Ollama auto model-swap (:11434) |
| Chat+RAG UI | Open WebUI (py3.12, :3000) | AnythingLLM desktop installer | LM Studio |
| IDE autocomplete | Continue.dev | twinny | LM Studio + Continue |
| Plan ≠ edit | aider architect | Cline single-model | — |
| Embeddings | bge-m3 | nomic-embed-text | Open WebUI built-in nomic |

## Engine won't build (CUDA pain)
- **Prebuilt llama.cpp:** grab `*-bin-win-cuda-12.4-x64.zip` from
  [llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases), or `scoop install llama.cpp-cu124`,
  and put the binaries in `bin/`. Runs on Blackwell, slightly slower than a 12.8 source build; skips the
  whole toolchain. (Also copy the matching CUDA DLLs into `bin/`, like `build-llama.ps1` does.)
- **Ollama (nuclear option):** official Blackwell support, no build. Install it, then repoint every tool to
  `http://localhost:11434/v1`. Lower peak perf, but everything else in this repo (Continue/aider/Open WebUI
  configs) works unchanged — just change the `apiBase`/port.

## No Go for llama-swap
Download the native Windows `llama-swap.exe` from
[llama-swap releases](https://github.com/mostlygeek/llama-swap/releases) into `bin/`. Skip `build-llama-swap.ps1`.

## Cline plan/act bug (#8126/#1987)
Distinct Plan-vs-Act models don't work over an OpenAI-compatible endpoint as of 2026. Options:
- Run Cline single-model (`coder`) — agentic edits still work fine.
- Use **aider architect mode** for true planner≠editor (`config/aider/.aider.conf.yml`).

## Open WebUI won't install (Python)
Needs Python 3.11/3.12 (3.14 too new, 3.10 too old). It lives in its **own** venv (`tools/venv-webui`),
separate from aider (`tools/venv-aider`) — their dependency pins conflict (`ddgs`), so never merge them
into one venv. If pip still fails, use the **AnythingLLM** desktop installer (no Python) — add the OpenAI
connection `http://localhost:8080/v1`, pick a separate embedding backend, organize docs per workspace.

## Model 404 on fetch
HF repo/filename changed or the quant name differs. Open the repo on huggingface.co, copy the exact
filename, fix the line in `models/models.manifest`, rerun `scripts\fetch-models.ps1`.
