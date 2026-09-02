#!/usr/bin/env bash
# llmctl-template.sh — parameterized personal model manager (llmctl-style).
# Distilled from an existing working manager; adapt the VARS block to your device
# (fill BACKEND_FLAGS from scripts/detect-device.sh, set MODEL_DIR / PIN_CPUS).
#
# Subcommands:  list | start <name|#|name@variant> [args...] | stop | status
#               profile <name|#> [variant] [args...] | profile --show [name]
#               client [<model|#> [variant]] [-- <command>...]  (generic OpenAI-compatible wiring)
#
# One chat server at a time. Profiles are single-line llama-server arg files,
# stored at <PROFILE_DIR>/<model> and <PROFILE_DIR>/<model>@<variant>.
# IMPORTANT: profile files MUST end with a trailing newline (missing \n breaks read).
set -euo pipefail

# ============================== VARS (adapt) ==============================
MODEL_DIR="${MODEL_DIR:-$HOME/models}"                 # dir scanned recursively for *.gguf
STATE_DIR="${STATE_DIR:-$HOME/.local/state/llmctl}"
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/llmctl}"
PROFILE_DIR="${PROFILE_DIR:-$CONFIG_DIR/profiles}"
LOG_DIR="${LOG_DIR:-$HOME/.local/log}"

# llama-server binary; override with LLMCTL_SERVER=/path/to/llama-server
SERVER_BIN="${LLMCTL_SERVER:-}"
if [ -z "$SERVER_BIN" ] && [ -x "$HOME/llama.cpp/build/bin/llama-server" ]; then
    SERVER_BIN="$HOME/llama.cpp/build/bin/llama-server"
elif [ -z "$SERVER_BIN" ]; then
    SERVER_BIN="${LLMCTL_SERVER:-/usr/bin/llama-server}"
fi

# Backend flags for YOUR device (fill from detect-device.sh). Examples:
#   Intel/AMD integrated or Intel Arc            → -ngl -1 --no-mmap
#   NVIDIA (CUDA build)                          → -ngl -1
#   Apple Silicon (Metal build)                  → -ngl -1
#   CPU-only build                               → (empty)
BACKEND_FLAGS="${LLMCTL_BACKEND_FLAGS:--ngl -1 --no-mmap}"

# Pin to performance cores if your CPU has P/E topology. Override with LLMCTL_PIN_CPUS.
# Find the P-core list from lscpu -p / cpu topology sysfs on Linux.
PIN_CPUS="${LLMCTL_PIN_CPUS:-}"

# Default port / context for a plain `start` with no args.
DEFAULT_PORT=8080

# Some GPU drivers need serialized submissions to avoid DeviceLost races with
# IQ-quantized weights on large prefill + stream + tools. Safe default on.
export GGML_VK_SERIALIZE_SUBMISSIONS="${GGML_VK_SERIALIZE_SUBMISSIONS:-1}"
# ===========================================================================

mkdir -p "$STATE_DIR" "$LOG_DIR" "$PROFILE_DIR"

# --- display ---
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
    C_RESET= C_BOLD= C_DIM= C_CYAN= C_GREEN= C_YELLOW= C_RED=
fi

section() { printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "$1" "$C_RESET"; }

summarize_args() {
    local text="$1" out="" key v
    for key in -c -t --temp --port; do
        v=$(printf '%s' "$text" | tr ' ' '\n' | grep -A1 -- "^${key}$" | tail -1 || true)
        [ -n "$v" ] && [[ "$v" != -* ]] && out+="${key} ${v}  "
    done
    local rv; rv=$(printf '%s' "$text" | tr ' ' '\n' | grep -A1 -- '^--reasoning$' | tail -1 || true)
    [ -n "$rv" ] && out+="think:$rv  "
    printf '%s' "$out"
}

list_profile_variants() {
    local name="$1" base; base=$(profile_file "$name")
    [ -f "$base" ] && printf "    %sdefault%s  %s\n" "$C_GREEN" "$C_RESET" \
        "$(summarize_args "$(tr '\n' ' ' < "$base")")"
    local f
    for f in "$PROFILE_DIR/$name@"*; do
        [ -f "$f" ] || continue
        printf "    %s@%s%s  %s\n" "$C_YELLOW" "${f##*@}" "$C_RESET" \
            "$(summarize_args "$(tr '\n' ' ' < "$f")")"
    done
}

# --- helpers ---
find_models() { (find -L "$MODEL_DIR" -name "*.gguf" -type f 2>/dev/null || true) | sort; }
model_name() { basename "$1" .gguf; }
profile_file() { local name="$1" variant="${2:-}"; [ -n "$variant" ] && echo "$PROFILE_DIR/$name@$variant" || echo "$PROFILE_DIR/$name"; }

find_model_by_query() {
    # Resolve "#index" or name-substring to a model path.
    # ALWAYS returns 0: under `set -e`, a non-zero return here would kill the
    # script inside `x=$(find_model_by_query ...)` before the caller could
    # print its friendly "Model not found" message. Callers check for empty.
    local query="$1"
    if [[ "$query" =~ ^[0-9]+$ ]]; then
        local i=1 total model
        total=$(find_models | wc -l | tr -d ' ')
        if [ "$query" -lt 1 ] || [ "$query" -gt "$total" ]; then
            return 0    # out of range -> empty; do NOT fall through to grep
                        # (a bare number like 5 would silently match "qwen2.5...")
        fi
        while IFS= read -r model; do
            if [ "$i" -eq "$query" ]; then echo "$model"; return 0; fi
            i=$((i+1))
        done < <(find_models)
        return 0
    fi
    local m=""
    m=$(find_models | grep -i -e "$query" | head -n 1 || true)
    [ -n "$m" ] && echo "$m"
    return 0
}

port_of() { printf '%s\n' "$1" | tr ' ' '\n' | grep -A1 -- '^--port$' | tail -1 || true; }

# --- commands ---
cmd_list() {
    local i=1 model name output
    section "Models in $MODEL_DIR"
    while IFS= read -r model; do
        printf "  %s%2d%s) %s%s%s\n" "$C_DIM" "$i" "$C_RESET" "$C_GREEN" "$(model_name "$model")" "$C_RESET"
        i=$((i+1))
    done < <(find_models)
    echo ""
    local has=0
    while IFS= read -r model; do
        name=$(model_name "$model")
        output=$(list_profile_variants "$name")
        if [ -n "$output" ]; then
            [ "$has" -eq 0 ] && section "Profiles" && has=1
            printf "  %s%s%s\n" "$C_BOLD$C_GREEN" "$name" "$C_RESET"
            echo "$output"
        fi
    done < <(find_models)
    if [ "$has" -eq 0 ]; then echo "Profiles: (none)"; fi
    return 0
}

stop_chat() {
    local pid
    if [ -f "$STATE_DIR/chat.pid" ]; then
        pid=$(cat "$STATE_DIR/chat.pid")
        if kill -0 "$pid" 2>/dev/null; then
            # Identity check before killing: a recycled PID could belong to an
            # unrelated process — never kill blindly off a stale pid file.
            local cmdline bin_name
            cmdline=$(ps -p "$pid" -o args= 2>/dev/null || true)
            bin_name=$(basename "$SERVER_BIN")
            case "$cmdline" in
                *llama-server*|*"$bin_name"*)
                    [ -z "${1:-}" ] && echo "Stopping chat server (PID $pid)"
                    kill -TERM "$pid" 2>/dev/null || true
                    # Graceful shutdown: llama-server may need a moment (ubatch
                    # flush, model unload). Wait up to 10s before SIGKILL.
                    local i=0
                    while [ $i -lt 10 ]; do
                        kill -0 "$pid" 2>/dev/null || break
                        sleep 1; i=$((i+1))
                    done
                    if kill -0 "$pid" 2>/dev/null; then
                        kill -KILL "$pid" 2>/dev/null || true
                    fi
                    ;;
                *)
                    echo "Stale pid file (PID $pid is not ${bin_name}: ${cmdline:-process gone}), cleaning"
                    ;;
            esac
        elif [ -z "${1:-}" ]; then
            echo "Chat: stale pid file, cleaning"
        fi
        rm -f "$STATE_DIR/chat.pid" "$STATE_DIR/chat.model" "$STATE_DIR/chat.args" "$STATE_DIR/chat.type"
    elif [ -z "${1:-}" ]; then
        echo "Chat: not running"
    fi
}

cmd_start() {
    if [ -z "${1:-}" ]; then
        echo "Usage: llmctl start <name|#> [variant] [llama-server args...]"
        cmd_list; exit 1
    fi
    local query="$1"; shift
    # Accept 'model@variant' → canonical two-arg form
    if [[ "$query" == *"@"* ]]; then
        local base="${query%%@*}" vtag="${query##*@}"
        if [ -n "$(find_models | grep -iF "$base" | head -1)" ]; then
            echo "Note: '$query' → model '$base' + variant '$vtag'"
            query="$base"; set -- "$vtag" "$@"
        fi
    fi
    local model_path name; model_path=$(find_model_by_query "$query")
    [ -z "$model_path" ] && { echo "Model not found: $query"; exit 1; }
    name=$(model_name "$model_path")

    local variant="" extra_args=("$@")
    if [ $# -gt 0 ] && [[ "$1" != -* ]] && [ -f "$(profile_file "$name" "$1")" ]; then
        variant="$1"; shift; extra_args=("$@")
    fi

    local profile_args=() pf; pf=$(profile_file "$name" "$variant")
    if [ -f "$pf" ]; then
        read -ra profile_args < "$pf" || true
        if [ ${#extra_args[@]} -eq 0 ]; then
            echo "Using profile for '$name${variant:+@$variant}': ${profile_args[*]}"
            set -- ${profile_args[@]+"${profile_args[@]}"}
        fi
    fi

    echo "Starting '${name}${variant:+@${variant}}'"
    echo "  command: llama-server -m $model_path $BACKEND_FLAGS $*"
    stop_chat quiet
    sleep 1

    # Port-busy guard — never launch into an occupied port (silent-wrong-server trap)
    local dport; dport=$(port_of "$*"); dport="${dport:-$DEFAULT_PORT}"
    if command -v ss >/dev/null && ss -ltn 2>/dev/null | grep -q ":${dport} "; then
        local owner; owner=$(ss -ltnp 2>/dev/null | grep ":${dport} " | grep -oP 'pid=\K[0-9]+' | head -1)
        printf '%sPort %s already bound%s\n' "$C_RED" "$dport" "$C_RESET"
        [ -n "$owner" ] && echo "  owner pid $owner: $(ps -p "$owner" -o args --no-headers 2>/dev/null | head -c 110)"
        echo "  kill it first:  kill ${owner}   # or use a different --port"
        exit 1
    fi

    local launch_prefix=()
    if [ -n "$PIN_CPUS" ] && command -v taskset >/dev/null; then
        launch_prefix=(taskset -c "$PIN_CPUS")
    fi

    nohup ${launch_prefix[@]+"${launch_prefix[@]}"} "$SERVER_BIN" -m "$model_path" $BACKEND_FLAGS "$@" \
        > "$LOG_DIR/llmctl-chat.log" 2>&1 &
    local pid=$!
    echo "$pid" > "$STATE_DIR/chat.pid"
    echo "$name" > "$STATE_DIR/chat.model"
    printf '%s\n' "$BACKEND_FLAGS $*" > "$STATE_DIR/chat.args"
    echo "single" > "$STATE_DIR/chat.type"
    echo "Started PID $pid"

    # Early-death check — catch instant crashes (bad flag, port race)
    sleep 2
    if ! kill -0 "$pid" 2>/dev/null; then
        printf '%sServer exited immediately — last log lines:%s\n' "$C_RED" "$C_RESET"
        tail -n 8 "$LOG_DIR/llmctl-chat.log" | sed 's/^/  /'
        exit 1
    fi

    # Built-in health wait (non-fatal)
    local i=0
    while [ $i -lt 10 ]; do
        curl -s --max-time 2 "http://127.0.0.1:${dport}/health" 2>/dev/null | grep -q ok && break
        sleep 2; i=$((i+1))
    done
    if [ $i -lt 10 ]; then
        printf '%sHealth: ok%s  (%s)\n' "$C_GREEN" "$C_RESET" "http://127.0.0.1:${dport}"
    else
        printf '%sHealth: loading…%s  follow with: status | log -f\n' "$C_YELLOW" "$C_RESET"
    fi

    # Priority boost (optional, needs passwordless sudo)
    if command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
        sudo renice -n -10 -p "$pid" >/dev/null 2>&1 || true
        for tid in $(python3 -c "
import glob
pid=int('$pid')
for t in glob.glob(f'/proc/{pid}/task/*'):
    tid=t.rsplit('/',1)[1]
    try:
        a=open(f'{t}/stat').read().rpartition(')')[2].split()
        if a[0] in ('R','S') and int(a[16])==0: print(tid)
    except: pass" 2>/dev/null); do
            sudo renice -n -10 -p "$tid" >/dev/null 2>&1 || true
        done
        echo -1000 | sudo tee "/proc/$pid/oom_score_adj" >/dev/null 2>&1 || true
    fi
}

cmd_profile() {
    if [ "${1:-}" = "--show" ]; then
        shift
        if [ -z "${1:-}" ]; then
            local any=0 model name output
            while IFS= read -r model; do
                name=$(model_name "$model"); output=$(list_profile_variants "$name")
                [ -n "$output" ] && { [ "$any" -eq 0 ] && echo "Profiles:" && any=1; echo "  $name:"; echo "$output"; }
            done < <(find_models)
            if [ "$any" -eq 0 ]; then echo "Profiles: (none)"; fi
        else
            local query="$1"; shift; local variant=""
            [ $# -gt 0 ] && [[ "$1" != -* ]] && variant="$1"
            local mpath; mpath=$(find_model_by_query "$query")
            [ -z "$mpath" ] && { echo "Model not found: $query"; exit 1; }
            local name; name=$(model_name "$mpath")
            if [ -n "$variant" ]; then
                local pf; pf=$(profile_file "$name" "$variant")
                [ -f "$pf" ] && echo "Profile for '${name}@${variant}': $(tr '\n' ' ' < "$pf")" \
                           || echo "No profile for '${name}@${variant}'"
            else
                list_profile_variants "$name"
            fi
        fi
        return 0
    fi
    [ -z "${1:-}" ] && { echo "Usage: llmctl profile <name|#> [variant] [args...]"; cmd_list; exit 1; }
    local query="$1"; shift
    local mpath; mpath=$(find_model_by_query "$query")
    [ -z "$mpath" ] && { echo "Model not found: $query"; exit 1; }
    local name; name=$(model_name "$mpath")
    local variant=""
    [ $# -gt 0 ] && [[ "$1" != -* ]] && { variant="$1"; shift; }
    local pf; pf=$(profile_file "$name" "$variant")
    local label="${name}${variant:+@$variant}"
    if [ $# -eq 0 ]; then
        rm -f "$pf"; echo "Removed profile for '$label'"
    else
        printf '%s\n' "$*" > "$pf"   # trailing \n is mandatory — see note
        echo "Profile for '$label' set to: $*"
    fi
}

cmd_client() {
    # Ensure the server for <model> is running & healthy, then exec the given
    # command with OpenAI-compatible env pointing at it. Tool-agnostic: any
    # client that honors OPENAI_BASE_URL / OPENAI_API_KEY works.
    # Usage: llmctl client [<model|#> [variant]] [-- <command> [args...]]
    #   with no -- <command>, print the equivalent export lines instead.
    local start_args=() client_args=() seen=0 a
    for a in "$@"; do
        [ "$a" = "--" ] && { seen=1; continue; }
        if [ "$seen" = 1 ]; then client_args+=("$a"); else start_args+=("$a"); fi
    done
    local running_model="" rargs="" port=""
    if [ -f "$STATE_DIR/chat.pid" ] && kill -0 "$(cat "$STATE_DIR/chat.pid")" 2>/dev/null; then
        running_model=$(cat "$STATE_DIR/chat.model" 2>/dev/null)
        rargs=$(cat "$STATE_DIR/chat.args" 2>/dev/null)
        port=$(port_of "$rargs"); port="${port:-$DEFAULT_PORT}"
    fi
    if [ ${#start_args[@]} -gt 0 ]; then
        local query="${start_args[0]}" mpath rname
        mpath=$(find_model_by_query "$query")
        [ -z "$mpath" ] && { echo "Model not found: $query"; exit 1; }
        rname=$(model_name "$mpath")
        if [ "$running_model" != "$rname" ]; then
            cmd_start ${start_args[@]+"${start_args[@]}"}
            running_model=$(cat "$STATE_DIR/chat.model")
            rargs=$(cat "$STATE_DIR/chat.args")
            port=$(port_of "$rargs"); port="${port:-$DEFAULT_PORT}"
        else
            echo "Server already running '$rname' — reusing"
        fi
    fi
    if [ -z "$running_model" ]; then
        echo "No server running. Usage: client <model|#> [variant] [-- command args...]"
        exit 1
    fi
    local i=0
    while [ $i -lt 90 ]; do
        curl -s --max-time 2 "http://127.0.0.1:${port}/health" 2>/dev/null | grep -q ok && break
        sleep 2; i=$((i+1))
    done
    if [ $i -ge 90 ]; then echo "Server health check timed out on port $port"; exit 1; fi
    local base_url="http://127.0.0.1:${port}/v1"
    printf "%sendpoint%s %s\n" "$C_GREEN" "$C_RESET" "$base_url"
    if [ ${#client_args[@]} -eq 0 ]; then
        cat <<EOF
Wire your client (any OpenAI-compatible tool):
  export OPENAI_BASE_URL=$base_url
  export OPENAI_API_KEY=local   # any non-empty value; llama-server ignores it unless --api-key is set
EOF
        return 0
    fi
    exec env OPENAI_BASE_URL="$base_url" OPENAI_API_KEY="${OPENAI_API_KEY:-local}" \
        ${client_args[@]+"${client_args[@]}"}
}

cmd_status() {
    local pid
    echo "=== Chat ==="
    if [ -f "$STATE_DIR/chat.pid" ]; then
        pid=$(cat "$STATE_DIR/chat.pid")
        if kill -0 "$pid" 2>/dev/null; then
            local type; type=$(cat "$STATE_DIR/chat.type" 2>/dev/null || echo single)
            if [ "$type" = "router" ]; then
                printf "Running  PID %s (router mode)\n" "$pid"
            else
                printf "%sRunning%s  PID %s\n" "$C_GREEN" "$C_RESET" "$pid"
                printf "Model      %s\n" "$(cat "$STATE_DIR/chat.model" 2>/dev/null || echo unknown)"
            fi
            local args; args=$(cat "$STATE_DIR/chat.args" 2>/dev/null || echo none)
            printf "Key params %s\n" "$(summarize_args "$args")"
            local rmodel variant="custom" pf
            rmodel=$(cat "$STATE_DIR/chat.model" 2>/dev/null)
            for pf in "$PROFILE_DIR/$rmodel" "$PROFILE_DIR/$rmodel@"*; do
                [ -f "$pf" ] || continue
                if [ "$(cat "$pf")" = "$args" ]; then
                    variant=$([ "$pf" = "$PROFILE_DIR/$rmodel" ] && echo default || echo "${pf##*@}")
                    break
                fi
            done
            printf "Profile    %s\n" "$variant"
            local port; port=$(port_of "$args"); port="${port:-$DEFAULT_PORT}"
            printf "Endpoint   http://127.0.0.1:%s\n" "$port"
            if curl -s --max-time 2 "http://127.0.0.1:${port}/health" | grep -q ok; then
                printf "Health     %sok%s\n" "$C_GREEN" "$C_RESET"
            else
                printf "Health     %sloading/unreachable%s\n" "$C_YELLOW" "$C_RESET"
            fi
        else
            echo "Not running (stale pid file)"
            rm -f "$STATE_DIR/chat.pid" "$STATE_DIR/chat.model" "$STATE_DIR/chat.args" "$STATE_DIR/chat.type"
        fi
    else
        echo "Not running"
    fi
}

cmd_log() {
    if [ "${1:-}" = "-f" ]; then tail -f "$LOG_DIR/llmctl-chat.log"
    else tail -n "${1:-20}" "$LOG_DIR/llmctl-chat.log"; fi
}
cmd_stop() { stop_chat; }

cmd_help() {
    cat <<'EOF'
Usage: llmctl <command> [args]

Commands:
  list                                    list all .gguf models and saved profiles
  start <name|#|name@variant> [args...]   start a model; variant = 2nd arg or name@variant
  client [<model|#> [variant]] [-- cmd]   ensure server + health, then exec cmd with
                                          OPENAI_BASE_URL/OPENAI_API_KEY set
                                          (works with any OpenAI-compatible client;
                                           no cmd: print the export lines)
  profile <name|#> [variant] [args...]    set/remove a profile (or variant)
  profile --show [name|#] [variant]       show profile(s)
  stop                                    stop the running chat
  status                                  show running chat
  log [-f|N]                              show log: -f follows, N = last N lines (20)
  help                                    show this help

Common llama-server args:
  -c N, --ctx-size N       context size in tokens
  -np N, --parallel N      number of slots
  --port PORT              listen port (default 8080)
  -ngl N, --gpu-layers N   GPU layers (only if GPU backend compiled)
  -t N, --threads N        CPU threads

Notes:
  - Profiles stored in <PROFILE_DIR>/, named "<ModelName>" or "<ModelName>@variant".
  - Profile files must end with a trailing newline (missing \n silently breaks reads).
  - 'start' without extra args uses the saved profile (default or variant).
  - 'client' is tool-agnostic: any OpenAI-compatible CLI/chat UI that accepts a
    custom base URL can be pointed at the local endpoint.
EOF
}

case "${1:-help}" in
    list) cmd_list ;;
    client) shift; cmd_client "$@" ;;
    start) shift; cmd_start "$@" ;;
    profile) shift; cmd_profile "$@" ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    log) shift; cmd_log "$@" ;;
    help|--help|-h) cmd_help ;;
    *) echo "Unknown command: $1"; cmd_help; exit 1 ;;
esac
