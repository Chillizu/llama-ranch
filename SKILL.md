---
name: llama-ranch
description: Run, swap, tune, and recommend local GGUF LLMs on any GPU via llama.cpp. Use when the user wants to deploy a local model, pick a model that fits their VRAM/RAM, quantize or set context/threads/samplers for their hardware, debug llama.cpp crashes or reasoning-template bugs, or build a personal model manager (llmctl-style). Also for local agentic coding with pi/OpenCode against a local OpenAI-compatible endpoint. Triggers on mentions of llama.cpp, local LLM, GGUF, GPU offload, quantization, VRAM, or "run a model locally" — even if the user doesn't name a tool.
---

# Local LLM on any device (llama.cpp)

Device-agnostic guide to run, recommend, and tune local GGUF models on whatever hardware is present. Detects the machine, picks a model that fits its memory, tunes inference-time settings, and optionally wires it into an agentic client.

## When to use

- Deploy / swap / stop a local model on this machine (llama.cpp `llama-server` or a `llmctl`-style manager).
- Pick a model + quantization that fits the device's VRAM/RAM and context needs.
- Set context size, threads, KV-cache type, samplers, reasoning off/on.
- Debug llama.cpp crashes (`DeviceLost`, reasoning-content swallowed, tool-call garbage, KV corruption).
- Build a personal model manager script, or connect pi/OpenCode to a local endpoint.

0. **Bootstrap** (fresh machine, no llama.cpp yet) → ensure a `llama-server` binary and a model file exist: build/install llama.cpp with the backend matching `detect-device.sh`, verify `llama-server --list-devices`, download a `.gguf` into `MODEL_DIR`. See `references/bootstrap.md`.
1. **Detect** the device → `scripts/detect-device.sh` (OS, GPU vendor/model/memory, shared-vs-dedicated, RAM, CPU cores incl. efficiency topology, suggested backend). See `references/device-detection.md`.
2. **Pick** a model → `scripts/recommend-models.sh "<name>" --ram <gib>` (live HuggingFace search, GGUF quants + sizes, fits hints). Capacity math + KV-cache budget in `references/model-selection.md`.
3. **Tune** inference → quantization, `-c` context, `-t` threads, KV-cache type, samplers in `references/tuning.md`.
4. **Run** → `llama-server -m model.gguf <flags>` (or the `llmctl-template.sh` manager). Verify with `curl /health` then one `/v1/chat/completions`.
5. **Wire agentic** (optional) → pi/OpenCode against the local OpenAI-compatible endpoint in `references/agentic.md`.
6. **Fix** crashes / bad output → generic bug/fix matrix in `references/stability.md`.

## Key invariants (apply regardless of hardware)

- **Capacity**: `weights_GiB + KV(ctx) + ~2 GiB buffer ≤ available memory`. Weights go in VRAM if a GPU backend offloads them; on shared-memory GPUs that heap is carved from system RAM — use *available* RAM, not nominal total.
- **Never assume quant-lower = faster**: on some backends the dequant shader for IQ quants is heavier than K-quants; decode is bounded by `weights_GiB / effective_bandwidth`. Always measure, never extrapolate from one run.
- **KV cache**: `fp16` is the safe default; `q8_0` can corrupt multi-turn state on some backends (greedy garbage / repetition); `q4_0` saves ~75% KV memory and is safe on most backends. KV memory grows linearly with `-c`.
- **Reasoning-preserving templates** (Qwen3, gemma-4, MiniCPM5): the chat template can swallow the whole output into `reasoning_content`, leaving `content:''`. Set `--reasoning off --reasoning-format deepseek` and assert `content` is non-empty.
- **Context limits are native**: YaRN / rope-scale only interpolate positions — they do not reduce KV memory or add memory past the model's native `context_length`. They only matter *beyond* it.
- **One slot per client**: `-np` splits the total context across slots; a single interactive/agent client should use `-np 1` so the whole `-c` goes to one slot.
- **Agentic needs a real model**: tool-call reliability collapses below ~12B. Small models are fast at chat but useless for coding agents — verify tool calls with `curl` before believing them.

## Scripts

| script | purpose |
|---|---|
| `scripts/detect-device.sh` | one-shot device capability report → JSON + suggested backend |
| `scripts/recommend-models.sh` | live HuggingFace GGUF search + fits hints |
| `scripts/llmctl-template.sh` | parameterized personal model manager (list/start/stop/status/profile/pi) |

## References (read on demand)

- `references/bootstrap.md` — from-zero setup: build/install llama.cpp with the right backend, verify --list-devices, download a model.
- `references/tuning.md` — quantization / context / threads / samplers methodology, decode ceiling, decay behavior.
- `references/stability.md` — generic bug → fix matrix, regression recipe.
- `references/agentic.md` — local agentic via OpenAI-compatible endpoint, tool-call verification, bench methodology, pi wiring.
- `references/build-your-own-manager.md` — design + adapter steps for a personal model manager.
