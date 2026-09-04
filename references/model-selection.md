# Model selection

Picking a model + quantization that fits the device, based on a live HuggingFace search and a memory budget.

## Capacity formula (starting point)

```
weights_GiB + KV(ctx) + ~2 GiB buffer  ≤  available_memory
```

- **`available_memory`**:
  - dedicated GPU → `gpu_memory_gib` from detection.
  - shared GPU / CPU → `ram_available_gib` (available RAM minus OS/desktop headroom).
- **`weights_GiB`**: the `.gguf` file size at the chosen quantization (from the HF search).
- **`KV(ctx)`**: KV cache grows linearly with `-c`; see below.
- **`~2 GiB buffer`**: compute graph + active tensors + fragmentation.

After load, confirm the model actually fits where you think: on Linux `grep VmRSS /proc/<pid>/status` — if weights went to a shared GPU heap, RSS stays far below the weight file size (the heap is mapped, not resident in the process).

## KV-cache math

Per-token KV size for one layer pair:

```
KV_bytes/token = 2 × n_layers × n_kv_heads × head_dim × bytes_per_elt
```

- `n_layers`, `n_kv_heads` (GQA head count, usually ≪ n_heads), `head_dim` come from the GGUF header or the HF config.
- `bytes_per_elt`: `fp16` = 2, `q8_0` = 1, `q4_0` = 0.5.

Tradeoffs:

| type | KV memory | notes |
|---|---|---|
| `fp16` | baseline | **safe default**; most compatible |
| `q8_0` | 50% | can **corrupt multi-turn state** on some backends (greedy output becomes garbage / repeats) — avoid unless verified on your backend |
| `q4_0` | 25% | safe on most backends; use when you need a long context without blowing the budget |

KV memory grows linearly with `-c`: doubling context doubles KV. On a 9B-class model expect roughly 50–80 KiB/token at fp16 — 32K ≈ 2 GiB, 48K ≈ 3 GiB, 64K ≈ 4 GiB (weights aside). If a request errors with `exceed_context_size_error`, raise `-c` or shorten the client's tool/system prompt.

## Native context limits

YaRN / rope-scale **only interpolate positions** — they do not reduce KV memory and do not add memory past the model's native `context_length`. They matter only *beyond* the native limit. Inside it, adjusting `-c` up just preallocates more KV.

## Live-search decision tree

Use `scripts/recommend-models.sh "<family>" --ram <gib> [--ctx <tokens>]` — it queries the HF API for GGUF siblings, prints quant + size, and marks fits against your budget. Then:

1. **Size tier by memory**: divide available memory by ~1.4 (weights + KV + buffer) to get the weights ceiling, then pick the largest model family whose weights fit.
2. **Quantization**: start from the smallest quantization that the family is stable at (K-quants generally stable; IQ-quants smaller but backend-dependent — see `tuning.md`). "Lower quant = smaller" but **not** necessarily faster.
3. **Context by use**: short prompts / light tooling → 8K–16K; heavy tool-call agents → 32K–48K (a 10K–35K system+tool prompt needs it); very long sessions → 64K+ (KV alone is GBs — check the budget).
4. **Agentic use** → ≥12B and a tool-call-capable architecture; verify tool calls with `curl` (see `agentic.md`). Small models are fast at chat but useless for coding agents.

If the HF API is unreachable, fall back to `web_search "<family> GGUF site:huggingface.co"` and apply the same budget math to the sizes you find.
