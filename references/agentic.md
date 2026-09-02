# Agentic with a local model

Pointing any OpenAI-compatible agentic/coding client at llama-server, verifying tool calls, and benchmarking a model for agentic coding. Tool-agnostic: the skill does not assume a specific client — if it accepts a custom OpenAI-compatible base URL, it works.

## Wiring a client to the local endpoint

llama-server exposes the OpenAI-compatible API under `/v1` (`/v1/chat/completions`, `/v1/models`, …). Any client that can be pointed at a custom OpenAI-compatible base URL works:

- **base_url**: `http://127.0.0.1:<PORT>/v1`
- **api_key**: any non-empty value (llama-server ignores it unless started with `--api-key`)

Common wiring patterns, in order of preference:

1. **Env-var convention** — many CLIs honor `OPENAI_BASE_URL` + `OPENAI_API_KEY`:
   ```bash
   export OPENAI_BASE_URL=http://127.0.0.1:<PORT>/v1
   export OPENAI_API_KEY=local
   <your-client> ...
   ```
2. **`llmctl client`** (from the manager template) — ensures the server for the requested model is running and healthy, then either prints the export lines or execs a command of your choice with the env already set:
   ```bash
   llmctl client <model|#>              # print export lines
   llmctl client <model|#> -- <cmd> ... # exec <cmd> with env wired
   ```
3. **Client-side provider config** — clients with config files: add a provider of type "openai-compatible" (naming varies) with the base URL above and a dummy key.

- If the client silently falls back to a cloud provider (symptom: unexpected remote TPM/rate limits), the base URL is not being honored — confirm with the server log (`llmctl log -f`) or by stopping the server and watching the client error.
- **Thinking/reasoning**: server `--reasoning on` streams reasoning content; clients that expose a "thinking" toggle should be set to match. For agentic loops prefer reasoning OFF (per-step thinking before every tool call drags the loop; see `tuning.md`).

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

A 6-task battery, run through the same client and scored independently:

1. JSON parsing edge cases
2. LRU cache implementation
3. CSV dedup
4. thread counting
5. log-regex extraction
6. binary-search boundary cases

Score each task pass/fail by running the produced artifact against tests — do not trust the model's self-report. Compare models on the same tasks, same flags, same thermal state. Keep the task definitions and tests fixed in your own repo so comparisons stay meaningful over time.

## Operational gotchas

- **Silent stdout redirect**: when a CLI client's stdout is redirected to a file, it can look like "no output / timeout" while it is still decoding normally — check the server log for the generation progress lines before assuming a hang.
- **Orphaned requests**: killing a client leaves an orphaned request that occupies the single slot and makes everything else queue (deadlock look). If the slot is stuck, kill and restart the server.
- **Slot release latency**: after killing a client, the server finishes the current ubatch before freeing the slot (can take minutes for a huge request). Before re-sending a large request, confirm the slot is actually free.
- **Long tasks**: self-test-style tasks can emit 600+ tokens; at a slow decode rate budget ≥10 min timeout.
- **File-name drift**: the model may ignore the requested filename (asked for `solution.py`, delivered `json_parser.py`) — make the judge tolerant.
