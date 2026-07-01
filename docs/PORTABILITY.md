# Portability & the Provisioner Contract (Module NB)

Bob is two halves: a **portable Python runtime** (the agent loop, tools, HTTP server, sessions,
memory, MCP) and a **provisioner** (installs prerequisites, downloads models, wires clients, starts
the inference services). Module NB decoupled them so the runtime boots and runs on any OS *without*
PowerShell, while the rich Windows auto-install experience stays exactly as it was — as one
pluggable provisioner, not a hard dependency.

## The provisioner contract

A provisioner's *only* obligations to the runtime are:

1. **A resolvable config.** Either `data/config.json` exists (Windows: written by `Get-BobConfig`
   from the `.psd1` files), or the neutral sources resolve one — `config/defaults.json` +
   `config/user.json` via `scripts/bob_config.py` (`bob_core.load_config()` falls back to this when
   `data/config.json` is absent). See contract **C2**.
2. **A reachable endpoint.** An OpenAI-compatible chat endpoint on `litellmPort` (the Windows
   provisioner runs llama-swap + LiteLLM; a BYO setup can point at anything OpenAI-compatible).

*How* a provisioner satisfies these — auto-install vs bring-your-own — is entirely its business. The
runtime never assumes a particular provisioner ran; it **probes** at startup and degrades with a
clear message (`bob_core.capability_probe`).

## The Windows provisioner (unchanged)

The existing scripts are the **Windows provisioner** implementing the contract. Their behavior is
unchanged by NB:

- `install_prereqs.bat`, `setup.bat`, `scripts/bootstrap*.ps1` — prerequisites + venvs
- `scripts/fetch-models.ps1` — model downloads
- `scripts/up.ps1`, `scripts/start*.ps1` — service lifecycle
- `Get-BobConfig` (`scripts/_models.ps1`) — writes the full `data/config.json`

`bob setup` / `bob up` / `.\scripts\test-dry-run.ps1` are exactly as before.

## Bring-your-own-runtime (no PowerShell)

On a box with no provisioner you can satisfy the contract manually and get a working Bob **core**
(`agent`, `agent serve`, `agent mcp`) with zero PowerShell:

1. **Config.** Optionally drop a `config/user.json` to override defaults (same runtime shape, e.g.
   `{"agent": {"maxSteps": 8}, "litellmKey": "sk-..."}`); otherwise `config/defaults.json` alone
   yields a valid runtime config. Secrets (e.g. `litellmKey`, provider keys) resolve through the
   secret seam — env var, OS keychain, or `data/secrets.json` — never a git-tracked file (contract
   **C3**).
2. **Endpoint.** Point `litellmPort` at any running OpenAI-compatible endpoint.
3. **Run.** `python -m bob agent serve` (or `./bob agent serve`) starts the FastAPI agent server;
   `python -m bob agent "<goal>"` runs a one-shot. The startup probe prints a clear message if the
   endpoint is unreachable rather than assuming the Windows setup ran.

Data and state (`sessions.db`, `bob.db`, `schedules.json`, `logs/`) default to the repo-relative
`data/` and `logs/` dirs on every OS (contract **C4**); set `BOB_DATA_DIR` to relocate them (with a
one-time migration) for a future system-install mode.

## Front door (contract C1)

One shim routes every command per `config/verbs.json` (generated from the command registry in
`scripts/bob/registry.py`): orchestration/bootstrap commands run PowerShell; runtime commands run
`python -m bob`. `bob serve` is the **inference stack**; the agent HTTP server is `bob agent serve`
(`python -m bob agent serve`). A native non-Windows provisioner (Linux/macOS service management,
CUDA/Metal build) is a later module — NB makes the *runtime* portable and defines this contract.
