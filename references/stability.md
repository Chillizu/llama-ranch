# Stability matrix

Generic symptoms → root causes → fixes. No vendor-specific labels; verify the trigger on your backend before applying.

## Reasoning-preserving templates swallow output

- **Symptom**: everything lands in `reasoning_content`, `content` is empty.
- **Cause**: chat templates marked reasoning-preserving (e.g. Qwen3, gemma-4, MiniCPM5 families) route the whole generation into reasoning.
- **Fix**: `--reasoning off --reasoning-format deepseek`, and have the client assert `content` is non-empty.

## Server dies on large prefill + stream + tools

- **Symptom**: `DeviceLost` / GPU queue submit error after a big (~1500-token) prefill with streaming and tool calls.
- **Cause**: async submission race with IQ-quantized dequant shaders on some GPU drivers; K-quants are immune.
- **Fix**: enable serialized GPU submissions (`GGML_VK_SERIALIZE_SUBMISSIONS=1`, set by the template by default). Re-verify after changing quantization.

## Alive but greedy output is garbage / repeats

- **Symptom**: server healthy, but greedy output is garbled / repeats.
- **Cause**: KV cache poisoned by `q8_0`.
- **Fix**: use `fp16` or `q4_0` KV cache; do not set `-ctk/-ctv q8_0`.

## Tool arguments degenerate into a repeated character

- **Symptom**: tool call args become "assassass…" loops.
- **Cause**: default penalty samplers punish the JSON punctuation the tool format needs.
- **Fix**: `--samplers top_k;top_p;min_p;temperature` (drop `penalties`). Keep penalties in the *agentic* profile if that profile is verified to copy JSON exactly — distinguish the two cases (garbage loop ⇒ drop penalties; verified exact-copy ⇒ keep).

## Profile file missing trailing newline

- **Symptom**: manager `start` exits silently (exit 1) with no output.
- **Cause**: profile arg file written without a final `\n`; the `read -ra` fails under `set -e`.
- **Fix**: write profiles with a trailing `\n`; verify `tail -c1 <file> | od -An -c` shows `\n`. Managers should `read ... || true` defensively.

## Regression test

After any change, run: a large system prompt + `stream: true` + tools for 4 consecutive rounds; the server must stay alive and `content` must be non-empty. This catches the reasoning-swallow, DeviceLost, and KV-poison classes together.
