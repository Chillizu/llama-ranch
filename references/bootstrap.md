# Bootstrap: from zero to a running llama-server

Everything else in this skill assumes a `llama-server` binary and at least one model file already exist. This covers that one-time setup on a fresh machine. Run it once, then the rest of the workflow applies.

## 0. Check what you already have

```bash
command -v llama-server            # on PATH?
[ -x "$HOME/llama.cpp/build/bin/llama-server" ] && echo source build present
```

If neither, continue. If `llama-server` exists, skip straight to **Verify the backend** and **Get a model file**.

## 1. Install or build llama.cpp

Pick by your **detected backend** (`scripts/detect-device.sh` → `suggested_backend`) and OS.

**Package install** (fastest; often older or CPU-only):
- Debian/Ubuntu: `sudo apt install llama.cpp`
- macOS: `brew install llama.cpp`
- Windows: official prebuilt releases

**Build from source** (recommended when you want a GPU backend that matches the hardware):

```bash
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release <backend flag>
cmake --build build --config Release -j
```

Backend flag by vendor (from detection):

| vendor / GPU | cmake flag |
|---|---|
| NVIDIA | `-DGGML_CUDA=ON` |
| Intel integrated / Arc | `-DGGML_VULKAN=ON` |
| AMD discrete | `-DGGML_HIP=ON` (or `-DGGML_VULKAN=ON` as a simpler fallback) |
| Apple Silicon | `-DGGML_METAL=ON` (default on macOS) |
| CPU-only | *(no flag)* |

Binary: `build/bin/llama-server` (add `build/bin` to `PATH` or set `LLAMA_SERVER`).

## 2. Verify the backend

```bash
build/bin/llama-server --list-devices
```

Must list your GPU under the compiled backend (e.g. `Vulkan0: ...`, `CUDA0: ...`, `Metal: ...`). If it lists nothing but CPU, the build lacks that backend (rebuild with the flag) or the driver/runtime is missing (Vulkan ICD, CUDA driver, etc.). This is the ground truth — never trust `suggested_backend` alone.

## 3. Get a model file

1. Decide what fits via `scripts/recommend-models.sh "<name>" --ram <gib>`.
2. Put the `.gguf` in a dedicated models dir (the manager's `MODEL_DIR`, e.g. `~/models`).
3. Download:
   - HF CLI: `huggingface-cli download <org>/<repo> <file>.gguf --local-dir ~/models`
   - or `curl -L -o ~/models/<file>.gguf https://huggingface.co/<org>/<repo>/resolve/main/<file>.gguf`
4. Networks that block HF: route through a proxy (`HTTPS_PROXY=socks5h://127.0.0.1:7891 curl ...` or `--proxy socks5h://...`).

Keep a dedicated models dir; don't scatter `.gguf` files where the manager's recursive scan would pick up unrelated files.

## 4. Wire into the rest of the skill

- Point the tooling at your binary: `LLAMA_SERVER=/path/to/llama-server` (detect-device), `LLMCTL_SERVER=/path/to/llama-server` (llmctl-template).
- Set `MODEL_DIR` in the template to your models dir.
- Proceed to the main workflow: **Run** → **Tune** → **Agentic** → **Fix**.
