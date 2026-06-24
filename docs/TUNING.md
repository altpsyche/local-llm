# TUNING

## llama-swap config (generated from `config/models.psd1`)
`config/llama-swap.yaml` is **generated** by `scripts/gen-llama-swap.ps1` from the single source
[config/models.psd1](../config/models.psd1) (and regenerated on every `llm serve`). Edit the PSD1, not
the YAML. The generated YAML has this shape:
- `macros:` — reusable strings (the shared `llama-server` invocation, KV flags). Reference as `${name}`.
- `models:` — one named entry per model; `cmd` is the only required field. `${PORT}` is auto-assigned.
- `ttl: 0` — never auto-unload (used to pin `fim` + `embed`).
- `filters.setParams` — enforce sampling (temperature/top_p) server-side regardless of client.
- `groups:` with `swap: true` — members evict each other (only one big model resident at a time).

## Per-model launch flags (Blackwell / 16GB)
```
-ngl 99 -c 16384 --flash-attn on --cache-type-k q8_0 --cache-type-v q8_0
```
- `-ngl 99` — all layers on GPU. Lower it only if a model+context spills past 16GB.
- `--flash-attn on` — required; also the prerequisite for KV-cache quant. (This build needs the explicit `on`/`off`/`auto` value; a bare `--flash-attn` errors.)
- `--cache-type-k/v q8_0` — halves KV memory, negligible quality loss → more context or bigger model.
  - **Gemma 3 exception:** regresses with q8_0 KV — use f16 (drop the two cache-type flags) for Gemma.

## VRAM math (rules of thumb)
- Weights ≈ `params × bytes-per-weight`: Q4_K_M ≈ 0.56 GB/B, Q5 ≈ 0.70, Q8 ≈ 1.0.
- Add KV cache: ~1–2 GB at 4K ctx, ~3–5 GB at 32K (halved by q8_0 KV).
- 14B Q4_K_M ≈ 9–10 GB + ctx → fits 16GB. 30B-A3B Q4 ≈ 18 GB → light RAM offload (fast, 3B active).
- **MoE memory = TOTAL params**, not active. An 80B-A3B at Q4 ≈ 45 GB → heavy RAM offload.

## Perf check — confirm MMQ, not the cuBLAS trap
```powershell
llm bench            # = llama-bench on the 14B coder
```
Healthy on this RTX 5080: **pp512 ≈ 4300 t/s, tg128 ≈ 86 t/s** (14B Q4). If prefill is ~1000 t/s
(≈5–6× low), you're on the cuBLAS fallback → the build used CUDA 13.x or a stale cache.
Fix: `scripts\build-llama.ps1 -Force` (wipes `build/` and rebuilds) with CUDA **12.8**.
(Builds skip if `bin\llama-server.exe` already exists — use `-Force` to actually rebuild.)

## Bumping the llama.cpp submodule
```powershell
cd external\llama.cpp
git fetch origin; git checkout <new-commit-or-tag>
cd ..\..
.\scripts\build-llama.ps1 -Force   # rebuild (omit -Force and it would skip, seeing the old binary)
# if good, pin it:
git add external/llama.cpp; git commit -m "bump llama.cpp to <commit>"
```
Always re-verify the perf check above after a bump (Blackwell MMQ status can regress between commits).

## Swapping/adding a model
Everything lives in one place — `config/models.psd1`:
1. Add (or edit) the model under a profile: `repo`/`path` (HF source), `gguf` (local filename),
   `ctx`, and optionally `kv = $true`, `flags`, `setParams`, `ttl`/`pinned`, `embedding`.
2. (Optional) add its role to the `group.members` list to make it swap with the other big models.
3. Download + apply: `llm fetch` (pulls new GGUFs) then `llm serve` (regenerates the config + restarts).
   Preview downloads first with `llm fetch --list`.

For a whole alternate set (e.g. low-VRAM), add a new key under `profiles` and switch with
`llm profile <name>`. See [docs/USAGE.md](USAGE.md#changing-the-active-profile).
