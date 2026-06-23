# SETUP

## Hardware target
Windows 11, NVIDIA RTX 5080 (16GB VRAM, Blackwell `sm_120`), Ryzen 9 7950X3D, 64GB RAM.

## Prereqs
| Tool | Install |
|---|---|
| **CUDA Toolkit 12.8** | `winget install Nvidia.CUDA --version 12.8` (toolkit only; driver already present). **NOT 13.x.** |
| Python 3.12 | `scoop install python312` |
| Go | `scoop install go` (or use the llama-swap release binary) |
| Git, CMake, VS 2022 + C++ x64 | already present |

> `setup.bat` installs all of the above automatically if missing — you normally don't run these by hand.

### CUDA 12.8 ↔ MSVC gotcha
If `nvcc` rejects the newest VS 2022 toolset (`unsupported Microsoft Visual Studio version`):
- add `-DCMAKE_CUDA_FLAGS="-allow-unsupported-compiler"` to the cmake line in `scripts/build-llama.ps1`, **or**
- install a CUDA-12.8-supported MSVC v14.4x toolset via the VS Installer and select it.

## One-shot (recommended)
```powershell
git clone --recurse-submodules <your-remote> C:\local-llm
cd C:\local-llm
.\setup.bat            # installs CUDA 12.8 + Python 3.12 + Go, then bootstrap + wire clients
```
Idempotent. `setup.bat -SkipModels` skips downloads; `setup.bat -Launch` starts the stack after.
`setup.bat` → `scripts\setup.ps1`: installs prereqs, then runs `bootstrap.ps1` + `setup-clients.ps1` +
`install-cli.ps1` (which puts the **`llm`** command on PATH). Open a new terminal afterwards, then `llm up`.

## Build (just the build, prereqs already present)
```powershell
.\scripts\bootstrap.ps1            # submodules -> build engine+proxy -> venvs -> fetch models
# or: .\scripts\bootstrap.ps1 -SkipModels
```

## Build (manual / what bootstrap does)
1. `git submodule update --init --recursive`
2. `.\scripts\build-llama.ps1` — CUDA-12.8 build of `external/llama.cpp` → `bin/` (skips if already built; `-Force` to rebuild)
3. `.\scripts\build-llama-swap.ps1` — `go build` of `external/llama-swap` → `bin/`
4. venvs: `tools\venv-aider` + `tools\venv-webui` (separate — conflicting deps), each `pip install -r tools\*-requirements.txt`
5. `.\scripts\fetch-models.ps1` — download GGUFs per `models/models.manifest`
6. `.\scripts\install-cli.ps1` — put the `llm` command on PATH

## Submodule pinning
The repo records exact submodule commits. To use a Blackwell-verified `llama.cpp`:
```powershell
cd external\llama.cpp; git checkout <known-good-commit>; cd ..\..
git add external/llama.cpp; git commit -m "pin llama.cpp to <commit>"
```
See [TUNING.md](TUNING.md#bumping-the-llamacpp-submodule) for bumping later.

## Verify
```powershell
llm serve                 # start the endpoint (:8080)
llm models                # lists planner/coder/chat/fim/embed
llm bench                 # ~pp512 4300 t/s, tg128 86 t/s on RTX 5080 = fast MMQ path
llm chat coder "hi"       # end-to-end sanity
```
