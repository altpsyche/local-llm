# local-llm

This project sets up a private AI assistant on your Windows PC. The models run on your GPU with no cloud service involved, no API fees, and no internet connection required after the initial model download. The inference is fast enough for real-time autocomplete and responsive back-and-forth conversation.

After setup you have in-editor autocomplete as you type in VS Code, a chat panel for asking questions and reviewing code, a terminal coding agent (aider) that separates planning from editing so you can review proposed changes before anything is written to disk, a browser-based chat interface at `http://localhost:3000`, and a local embedding model for searching your own documents and codebase.

Everything routes through a single local server at `http://localhost:8080/v1`, which speaks the same protocol as the OpenAI API. Any tool already pointed at OpenAI can be redirected here instead.

You need Windows 11 and an NVIDIA GPU from the RTX 3000 series or newer. Setup detects your GPU automatically and selects the right CUDA toolkit and build flags. The default profile targets 16 GB VRAM (RTX 5080, Blackwell) and runs at about 86 tokens per second on generation. Profiles for 12 GB and 8 GB cards are included; the VRAM suggestion is automatic at setup.

## Quick start

```powershell
git clone --recurse-submodules <your-remote> C:\local-llm
cd C:\local-llm
.\setup.bat
llm up
```

`setup.bat` handles everything in one shot. It installs the required prerequisites (CUDA 12.8, Python, Go), builds the inference engine and proxy from source, downloads the model files (about 38 GB for the default 16 GB profile), and wires the VS Code and terminal clients. It's safe to re-run if something fails partway through.

After setup, open a new terminal so the PATH update takes effect, then run `llm up`. This starts the API endpoint on port 8080 and the web chat interface on port 3000.

Pass `-Profile 12gb` if your GPU has less than 16 GB of VRAM (about 21 GB download instead of 38). Pass `-SkipModels` to build everything but defer the downloads. Pass `-Launch` to start the stack automatically when setup finishes.

Once the stack is running, `llm up` is the only command you need at the start of each session. Use `llm serve` if you only want the API endpoint without the web UI. All other commands are in [docs/USAGE.md](docs/USAGE.md).

## Model profiles

All models are defined in `config/models.psd1`, grouped into VRAM profiles. The default is `16gb`. To see what's available and switch profiles:

```powershell
llm profiles          # list profiles with their VRAM requirements
llm profile 12gb      # switch profiles and regenerate the config
```

Setup reads your GPU automatically and switches to the best-fit profile if the active one won't fit. Pass `-Profile` explicitly to override the automatic choice. See [docs/USAGE.md](docs/USAGE.md) for adding custom profiles.

## CUDA versions

Setup detects your GPU and picks the right CUDA toolkit automatically. The only strict version requirement is for Blackwell (RTX 5000 series): those cards need CUDA 12.8 specifically for the hardware acceleration path that delivers the benchmark numbers above. Building Blackwell with any other version falls back to a code path roughly five times slower on prefill. For Ada Lovelace (RTX 4000 series) and Ampere (RTX 3000 series), any CUDA 12.x works. Details are in [docs/SETUP.md](docs/SETUP.md) and [docs/TUNING.md](docs/TUNING.md).

## Docs

[SETUP](docs/SETUP.md) covers prerequisites, install, build steps, and how to verify the stack is working.

[USAGE](docs/USAGE.md) covers daily commands, configuring each client (VS Code, aider, Open WebUI), and managing model profiles.

[TUNING](docs/TUNING.md) covers per-model launch flags, VRAM sizing, performance checks, and updating the inference engine.

[FALLBACKS](docs/FALLBACKS.md) covers alternatives and workarounds for when something won't build or install.
