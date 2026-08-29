# Inference-time tuning

"微调" here means **inference-time tuning only** — quantization level, context size, thread count, samplers, KV-cache type — to fit a given device. Not training.

## Quantization

- **K-quants** (`Q4_K_M`, `Q5_K_M`, …) are the stable middle ground.
- **IQ-quants** (`IQ3_XXS`, `IQ2_S`, …) are smaller but the dequant shader is heavier on some backends — **lower quant is not necessarily faster**. Measure decode, don't assume a smaller file is faster.
- If decode does not improve with a smaller quant, you've hit the dequant/bandwidth mix — stop there; further shrinking only loses quality.

## Context (`-c`)

| scenario | `-c` | note |
|---|---|---|
| short prompts, light tooling | 8192–16384 | fast, cheap |
| heavy tool / agent prompts | 32768–49152 | fits a 10K–35K system+tool prompt |
| very long sessions | 65536+ | KV alone is GBs — check budget |
| unset | model default (often large) | memory hog |

`-np` splits the total context across slots: **a single interactive/agent client should use `-np 1`** so the whole `-c` belongs to one slot. With `-np > 1`, each slot gets only `-c / np`.

## Threads (`-t`)

Sweep to find the decode sweet spot — restart with each `-t`, then time a short completion (max_tokens ~64, temp 0, twice, take the mean):

```bash
for t in 8 6 4 2; do
  restart server with -t $t
  curl /v1/chat/completions ×2 | jq .timings.predicted_per_second
done
```

Patterns (verify on your hardware, they vary):
- Large dense models: sweet spot near the physical P-core count (more logical threads than that hurts).
- Smaller models: often fastest at *fewer* threads (counter-intuitive) or insensitive.
- Sub-2B models: insensitive — keep a default.

**Decode ceiling** = `weights_GiB / effective_bandwidth`. Once decode stops improving with tuning you're at the ceiling — the only real levers are a smaller model/MoE or a faster bus. Stop tuning there.

## Decay behavior

- **decode decays as context fills** (fewer unused KV slots → more effective work per step).
- **prefill decays with prompt depth** (deeper segments are slower).
- Consequence: for very long contexts, **grow the context incrementally** and reuse the prompt cache; do not fill a huge context in one shot — the cost is far above the flat estimate.
- Cross-time comparisons are only valid at the same thermal state: a hot device throttles decode. If "it got slower", check temperature before suspecting config.

## Samplers

- **Tool-call degradation**: if tool arguments degenerate into repeating characters, the server's default penalty samplers are punishing JSON punctuation. Fix by excluding penalties and enumerating samplers explicitly:
  `--samplers top_k;top_p;min_p;temperature`
- **Agentic template**: deterministic tool loops want low temperature + controlled penalties and **reasoning/thinking OFF** (per-step thinking before every tool call drags the loop):
  ```
  --reasoning off --reasoning-format deepseek
  --temp 0.2 --top-p 0.85 --top-k 20 --min-p 0.1
  --presence-penalty 1.5 --repeat-penalty 1.1
  -c <ctx> -np 1 --jinja
  --samplers penalties;top_k;top_p;min_p;temperature
  ```
- Modern models already suppress repetition; over-strong penalties can hurt long-tail tokens. Measure before changing defaults — don't follow convention blindly.

## Priority (optional)

`renice -10` the main + active worker threads and set `oom_score_adj = -1000` (needs privileged access); lower `vm.swappiness` so the model's pages stay resident. Verify with `ps -o ni -p <pid>` → should be `-10`.
