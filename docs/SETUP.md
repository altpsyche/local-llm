# SETUP

## Hardware target
Windows 11, NVIDIA RTX 5080 (16GB VRAM, Blackwell `sm_120`), Ryzen 9 7950X3D, 64GB RAM.

## Prereqs
| Tool | Install |
|---|---|
| **CUDA Toolkit 12.8** | NVIDIA installer (toolkit only — driver 610.x already present). **NOT 13.x.** |
| Python 3.12 | `scoop install python312` |
| Go | `scoop install go` (or use the llama-swap release binary) |
| Git, CMake, VS 2022 + C++ x64 | already present |

### CUDA 12.8 ↔ MSVC gotcha
If `nvcc` rejects the newest VS 2022 toolset (`unsupported Microsoft Visual Studio version`):
- add `-DCMAKE_CUDA_FLAGS="-allow-unsupported-compiler"` to the cmake line in `scripts/build-llama.ps1`, **or**
- install a CUDA-12.8-supported MSVC v14.4x toolset via the VS Installer and select it.

## Build (automated)
```powershell
git clone --recurse-submodules <your-remote> C:\local-llm
cd C:\local-llm
.\scripts\bootstrap.ps1            # submodules -> build -> venv -> fetch models
# or: .\scripts\bootstrap.ps1 -SkipModels    (skip the multi-GB downloads)
```

## Build (manual / what bootstrap does)
1. `git submodule update --init --recursive`
2. `.\scripts\build-llama.ps1` — CUDA-12.8 build of `external/llama.cpp` → `bin/`
3. `.\scripts\build-llama-swap.ps1` — `go build` of `external/llama-swap` → `bin/`
4. venv: `python3.12 -m venv tools\venv312` then `pip install -r tools\requirements.txt`
5. `.\scripts\fetch-models.ps1` — download GGUFs per `models/models.manifest`

## Submodule pinning
The repo records exact submodule commits. To use a Blackwell-verified `llama.cpp`:
```powershell
cd external\llama.cpp; git checkout <known-good-commit>; cd ..\..
git add external/llama.cpp; git commit -m "pin llama.cpp to <commit>"
```
See [TUNING.md](TUNING.md#bumping-the-llamacpp-submodule) for bumping later.

## Verify
```powershell
.\scripts\start.ps1
curl http://localhost:8080/v1/models      # lists planner/coder/chat/fim/embed
```
