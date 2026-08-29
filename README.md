# llama-ranch

Device-agnostic Agent Skill for running, recommending, and tuning **local GGUF LLMs on any GPU** via [llama.cpp](https://github.com/ggml-org/llama.cpp).

Detects the machine, picks a model + quantization that fits its VRAM/RAM, tunes inference-time settings (quantization level, context length, threads, samplers, KV-cache type), runs a llama-server, and optionally wires an agentic client (pi / OpenCode) to the local OpenAI-compatible endpoint.

## Install

```bash
npx skills add Chillizu/llama-ranch
```

## What it does

- **Detect** the device → `scripts/detect-device.sh`: OS, GPU vendor/model/memory (dedicated vs shared heap), RAM, CPU cores incl. P/E split, suggested backend (vulkan / cuda / rocm / metal / cpu). Emits JSON.
- **Pick** a model → `scripts/recommend-models.sh "<name>" --ram <gib> [--ctx <tokens>]`: live HuggingFace GGUF search with per-quant file sizes and exact fp16 KV-cache budget → fits hints. No hardcoded model tables. Set `HF_PROXY` if your network blocks HF directly.
- **Tune** inference → `references/tuning.md`: capacity formula, KV-cache math (fp16 / q4_0 / q8_0 tradeoffs), `-c` context tiers, `-t` thread sweep, sampler setup, decode ceiling, decay behavior.
- **Run** → `llama-server -m model.gguf <flags>`, or build a personal manager from `scripts/llmctl-template.sh` (parameterized `list/start/stop/status/profile/pi`).
- **Fix** → `references/stability.md`: generic bug/fix matrix (reasoning-preserving template swallow, DeviceLost races, q8_0 KV poisoning, tool-arg degeneration, trailing-newline profile bug).
- **Agentic** → `references/agentic.md`: pi/OpenCode against the local endpoint, tool-call verification, 6-task agent bench methodology.

## Layout

```
SKILL.md                          frontmatter (name/description) + decision flow
scripts/detect-device.sh          one-shot device capability report → JSON
scripts/recommend-models.sh       live HuggingFace GGUF search + fits hints
scripts/llmctl-template.sh        parameterized personal model manager
references/*.md                   on-demand detail (bootstrap, detection, selection, tuning, stability, agentic, manager)
```

## Notes

- Inference-time tuning only — no training.
- Empirical insight is de-vendored: no device-specific throughput/memory numbers are hardcoded; measure on your hardware.
