# Device detection

How to map the machine to a runnable llama.cpp configuration, and how the JSON from `scripts/detect-device.sh` is meant to be read.

## Detection principles (per OS)

- **OS**: `uname -s` → linux / darwin / windows.
- **GPU vendor + model**:
  - Linux: `lspci -nn` filtering VGA / 3D controller / display controller. Vendor keywords: `intel`, `nvidia`, `AMD/Advanced Micro Devices/Radeon`, `Apple`.
  - macOS: `system_profiler SPDisplaysDataType` (Chipset / Model lines).
  - Cross-check the actual llama.cpp backend with `llama-server --list-devices` — it reports what the *compiled* backend actually sees, which is the ground truth for offload.
- **GPU memory**:
  - Dedicated VRAM: `nvidia-smi --query-gpu=memory.total`, or the device-local heap reported by `vulkaninfo --summary` when present.
  - **Integrated / shared-memory GPUs** (Intel iGPU/Arc, Apple Unified Memory, many AMD APUs): the "VRAM" is a heap carved from **system RAM**. Nominal device memory is meaningless here — budget with **available** RAM minus what the OS/desktop reserves. `gpu_memory_gib: null` + `memory_type: "shared"` means: count against `ram_available_gib`.
- **RAM**: Linux `free -b` MemAvailable; macOS `hw.memsize` (available is an estimate — confirm with htop/Activity Monitor).
- **CPU**: Linux `lscpu -p` (logical/physical) and `lscpu -e` MAXMHZ tiers for `cpu_efficient` (non-performance cores = those with max boost clearly below the top tier; 0 if no P/E split); macOS `hw.logicalcpu` / `hw.physicalcpu` / `hw.perflevel1.logicalcpu`.

## Backend mapping (vendor → llama.cpp backend flag)

| GPU | backend | typical flags |
|---|---|---|
| NVIDIA | CUDA | `-ngl -1` |
| AMD discrete | ROCm (HSA) | `-ngl -1` |
| Intel integrated / Arc | Vulkan | `-ngl -1 --no-mmap` |
| Apple Silicon | Metal | `-ngl -1` |
| none / CPU build | CPU | *(no GPU flags)* |

`-ngl -1` = offload all layers. Only use it when the capacity math in `references/model-selection.md` fits; otherwise reduce `-ngl N` for partial offload (usually slower than full offload or full CPU — measure).

## Output contract

`scripts/detect-device.sh` prints a human summary then one JSON line:

```json
{
  "os": "linux",
  "gpu_vendor": "intel",
  "gpu_model": "...",
  "gpu_memory_gib": null,
  "memory_type": "shared",
  "ram_gib": 30.0,
  "ram_available_gib": 9.6,
  "cpu_cores": 22,
  "cpu_physical": 16,
  "cpu_efficient": 8,
  "suggested_backend": "vulkan",
  "notes": ["integrated/shared-memory GPU: ..."]
}
```

Field semantics:

- `gpu_memory_gib`: `null` when the backend is shared-memory or the value couldn't be read. Treat as "no dedicated VRAM budget".
- `memory_type`: `dedicated` | `shared`.
- `cpu_efficient`: an estimate of non-performance (efficiency/LP) cores from `lscpu -e` max-boost-MHz tiers; `0` means no hybrid split detected. Use only as a hint — for exact P/E pinning read the CPU topology directly.
- `suggested_backend`: first guess; always confirm with `llama-server --list-devices` (a build compiled without the right backend silently falls back to CPU).
- `suggested_backend`: first guess; always confirm with `llama-server --list-devices` (a build compiled without the right backend silently falls back to CPU).

## Verification

Run `scripts/detect-device.sh` and cross-check the reported GPU against `llama-server --list-devices`. If the backend shows the GPU, offload flags will work. If `suggested_backend` says `vulkan` but `--list-devices` shows no GPU, the build is CPU-only or the driver is missing.
