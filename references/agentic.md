# Agentic with a local model

Running pi / OpenCode against a local OpenAI-compatible endpoint (llama-server), verifying tool calls, and benchmarking a model for agentic coding.

## Wiring pi to a local endpoint

A personal manager (`llmctl-template.sh`) automates this; the raw equivalent is:

```bash
LLAMA_SERVER_URL=http://127.0.0.1:<PORT> \
pi --provider "llama-server=http://127.0.0.1:<PORT>" \
   --model "/path/to/<model>.gguf" \
   --thinking off \
   -p "task" --no-session
```

- `LLAMA_SERVER_URL` must be set — without it pi falls back to a cloud provider (symptom: unexpected remote TPM limits).
- **Thinking mapping**: server `--reasoning on` → pi `--thinking medium`; `--reasoning off` → `--thinking off`. Keep `--thinking` under agent control (`--` passthrough overrides).
- A manager's `pi` subcommand: ensure the server is running (start if needed, reuse if the same model), wait for `/health` ok, then `exec` pi wired to that endpoint. Model mismatch auto-restarts the server for the requested model.

## Verifying tool calls

Before trusting a model for agentic work, confirm it actually emits tool calls over the OpenAI-compatible API:

```bash
curl -s http://127.0.0.1:<PORT>/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"local","messages":[{"role":"user","content":"Call the tool with arg x=1"}],
       "tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"x":{"type":"integer"}}}}}]}'
```

- Response has `tool_calls` → model can do tool calling.
- Response is plain assistant text → it ignored/refused tools.
- HTTP 500 with a "peg-native format" error → the llama.cpp tool parser doesn't recognize this architecture's tool markers (or the build is too old) → upgrade llama.cpp / use a tool-capable arch.

## Agentic capability rules of thumb

- **Small models are a trap for agents**: high chat speed, but tool-call reliability collapses below ~12B. A 1–3B model may "have tool calls" yet never produce working code. **For real agentic work use ≥12B.**
- A model can have *formally* working tool calls but produce broken code — tool-call support ≠ agent quality. Bench it.

## Agent coding bench (methodology)

A 6-task battery, run via pi and scored independently:

1. JSON parsing edge cases
2. LRU cache implementation
3. CSV dedup
4. thread counting
5. log-regex extraction
6. binary-search boundary cases

Score each task pass/fail by running the produced artifact against tests — do not trust the model's self-report. Compare models on the same tasks, same flags, same thermal state.

## Operational gotchas

- **Silent stdout redirect**: when pi's stdout is redirected to a file, it can look like "no output / timeout" while it is still decoding normally — check the manager's log for the `n_gen` line before assuming a hang.
- **Orphaned requests**: killing a client leaves an orphaned request that occupies the single slot and makes everything else queue (deadlock look). If the slot is stuck, kill and restart the server.
- **Slot release latency**: after killing a client, the server finishes the current ubatch before freeing the slot (can take minutes for a huge request). Before re-sending a large request, confirm the slot is actually free.
- **Long tasks**: self-test-style tasks can emit 600+ tokens; at a slow decode rate budget ≥10 min timeout.
- **File-name drift**: the model may ignore the requested filename (asked for `solution.py`, delivered `json_parser.py`) — make the judge tolerant.
