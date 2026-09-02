# Build your own manager

A personal, llmctl-style model manager is a thin wrapper over `llama-server`: it resolves a model query to a `.gguf`, assembles flags, manages the process, stores per-model profiles, and (optionally) wires an OpenAI-compatible client. `scripts/llmctl-template.sh` is a ready-to-adapt implementation; this file explains its design and how to adapt it.

## Design

State kept in `$STATE_DIR` (per-process files, not a database):

- `chat.pid` — running server PID.
- `chat.model` — resolved model name.
- `chat.args` — the exact llama-server args in use (needed to identify which profile matches, and to rebuild for `pi`).
- `chat.type` — `single` | `router`.

One chat server at a time: `start` stops the previous one first. This avoids GPU/RAM contention from two loaded models.

## Subcommands

| command | behavior |
|---|---|
| `list` | enumerate `.gguf` models (recursive scan, numbered) + saved profiles per model |
| `start <name\|#\|name@variant> [args…]` | resolve query → model, load profile (or variant), stop prior server, launch, health-wait |
| `stop` | terminate the running chat server |
| `status` | running model, key params, matching profile, endpoint, health probe |
| `profile <name> [variant] [args…]` | set/remove a profile (no args = remove) |
| `profile --show [name]` | view profile(s) |
| `client [<model|#> [variant]] [-- cmd…]` | ensure server + health, then exec `cmd` with `OPENAI_BASE_URL`/`OPENAI_API_KEY` set (no `cmd` → print the export lines) |

## Profiles

- Location: `<PROFILE_DIR>/<model>` for the default profile, `<PROFILE_DIR>/<model>@<variant>` for a named variant.
- Content: a **single line** of llama-server args.
- **Trailing newline is mandatory** — a missing `\n` makes `read -ra` fail silently under `set -e`. Write with `printf '%s\n'`, verify with `tail -c1 | od -An -c`.
- `start` with no extra args uses the saved default/variant profile; extra args override/append for that launch.

## UX safeguards worth keeping

- **`model@variant` sugar**: `start qwen longctx` and `start qwen@longctx` are equivalent; translate the latter to the two-arg form.
- **Port-busy guard**: before launching, check the target port; if an unrelated process owns it, abort and print the owner PID + kill hint. This prevents the "silent wrong server" trap (your request hitting an old instance on the same port).
- **Early-death check**: 2s after launch, if the PID died, dump the log tail and exit 1 (catches bad flags / port races instantly).
- **Built-in health wait**: poll `/health` (print `ok` or `loading…`); cold model load can take a while — `client` waits up to a generous timeout.
- **Priority boost**: `renice -10` + `oom_score_adj -1000` (needs privileged access), optional.
- **Status profile line**: `status` shows which saved profile (or `custom`) the running args match — important when a profile was overridden at launch.

## Adapting the template

1. **Paths**: set `MODEL_DIR`, `STATE_DIR`, `CONFIG_DIR`, `LOG_DIR` for your layout.
2. **Backend flags**: run `scripts/detect-device.sh`, then set `BACKEND_FLAGS` per the mapping in `references/device-detection.md` (e.g. `-ngl -1 --no-mmap` for Vulkan integrated; `-ngl -1` for CUDA/Metal).
3. **CPU pinning**: set `PIN_CPUS` to your P-core list (from `lscpu -p` / CPU topology sysfs) so decode doesn't run on efficiency cores.
4. **Defaults**: adjust `DEFAULT_PORT` and the default sampler/context set in `references/tuning.md` for your workload.
5. **Verify**: `list`, `start <model>`, `status` (health ok), `profile <model> -c 8192`, then `stop`. Wire `client` last, confirming `OPENAI_BASE_URL` reaches the local endpoint.

Rename the script (`llmctl-template.sh` → `llmctl` or your own name) and drop it on your `PATH`.
