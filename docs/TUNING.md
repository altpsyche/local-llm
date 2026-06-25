# TUNING

This document covers the internals of how the server is configured and how to get the most out of it: the launch flags the models run with, how to estimate VRAM requirements for different models, how to verify you're on the fast hardware path, and how to update the inference engine safely.

## How the server config is generated

`config/llama-swap.yaml` is generated automatically from [config/models.psd1](../config/models.psd1) by `scripts/gen-llama-swap.ps1` and regenerated every time you run `llm serve`. Don't edit the YAML by hand; edit the PSD1 file instead. Your changes to the YAML will be overwritten.

The generated YAML has this structure:

- `macros:` — reusable strings, mainly the shared `llama-server` command and KV cache flags, referenced as `${name}` in model entries
- `models:` — one named entry per model; `cmd` is the only required field; `${PORT}` is assigned automatically by the proxy
- `ttl: 0` on pinned models like `fim` and `embed`, which disables automatic unloading
- `filters.setParams` — enforces sampling settings (temperature, top_p) server-side regardless of what the client sends
- `groups:` with `swap: true` — models in the same group evict each other, so only one large model is resident at a time

## Per-model launch flags (Blackwell / 16GB)

The models run with these flags by default:

```
-ngl 99 -c 16384 --flash-attn on --cache-type-k q8_0 --cache-type-v q8_0
```

`-ngl 99` loads all layers onto the GPU. Lower this number only if a model plus its context spills past 16 GB; some layers will then fall back to CPU, which is slower but functional.

`--flash-attn on` enables Flash Attention, which is required for KV cache quantization. This build needs the explicit `on`/`off`/`auto` value; a bare `--flash-attn` without a value errors out.

`--cache-type-k q8_0` and `--cache-type-v q8_0` quantize the KV cache to 8-bit, which roughly halves its memory footprint with negligible quality loss. This lets you run a longer context or a larger model in the same VRAM. Exception: Gemma 3 models regress in quality with quantized KV cache; use `f16` (omit both cache-type flags) for any Gemma model.

## VRAM math

When deciding whether a model will fit, start with a rough estimate of weight memory plus KV cache.

Weight memory is approximately the number of parameters multiplied by the bytes per weight for that quantization level. Common values: Q4_K_M is about 0.56 GB per billion parameters, Q5 about 0.70, and Q8 about 1.0.

KV cache adds roughly 1 to 2 GB at a 4k context window, or 3 to 5 GB at 32k. Quantized KV cache (`q8_0`) cuts these figures in half.

For the models in this repo on 16 GB VRAM: the 14B Q4_K_M coder is about 9 to 10 GB for weights plus 1 to 2 GB for context, which fits comfortably. The 30B-A3B Q4 planner is about 18 GB for the full weight matrix, so it uses a small amount of RAM offload; but because only 3B parameters are active per token (it's a mixture-of-experts model), generation is still fast.

On mixture-of-experts models generally: VRAM requirements are based on the total parameter count, not just the active ones. The active parameter count affects compute speed but not how much memory you need to load the model. An 80B model with 3B active parameters at Q4 still needs roughly 45 GB for the weight matrix.

## Verifying the fast path

The most important health check is whether the engine is using Blackwell's optimized matrix multiplication (MMQ) rather than the slower cuBLAS fallback. The fallback is roughly five to six times slower on prefill.

```powershell
llm bench
```

Expected numbers on an RTX 5080 with the 14B Q4 coder model: **pp512 ≈ 4300 t/s, tg128 ≈ 86 t/s**.

If prefill is around 1000 t/s, you're on the cuBLAS fallback. This happens when the build used CUDA 13.x or when there's a stale build cache from a previous compile. Fix it by forcing a clean rebuild:

```powershell
.\scripts\build-llama.ps1 -Force
```

The `-Force` flag wipes the `build/` directory before compiling. Without it, the script sees the existing binary and skips the build entirely. Confirm CUDA 12.8 is the active toolkit before running.

## Updating the llama.cpp engine

New llama.cpp versions can add support for new models, fix bugs, or improve performance. Blackwell MMQ support can regress between commits, so always re-run the benchmark after a bump to confirm performance before committing the new pin.

```powershell
cd external\llama.cpp
git fetch origin
git checkout <new-commit-or-tag>
cd ..\..
.\scripts\build-llama.ps1 -Force
llm bench
```

If the numbers look good, pin the commit:

```powershell
git add external/llama.cpp
git commit -m "bump llama.cpp to <commit>"
```

If performance regressed, check back to the previous known-good commit.

## Adding or swapping a model

All model configuration lives in `config/models.psd1`. To add a new model or swap the backing GGUF for an existing role:

1. Edit the model entry: set `repo` and `path` (the HuggingFace source), `gguf` (the local filename), `ctx` (context size), and any optional flags (`kv`, `flags`, `setParams`, `ttl`, `pinned`, `embedding`).
2. Optionally add its name to `group.members` if it should swap with the other large models.
3. Run `llm fetch` to download the new GGUF, then `llm serve` to pick it up. Use `llm fetch --list` first to preview what will be downloaded.

To add an entirely new VRAM tier, add a new key under `profiles` in the PSD1 file and switch to it with `llm profile <name>`. See [USAGE.md](USAGE.md#managing-model-profiles).
