#!/usr/bin/env bash
# detect-device.sh — one-shot device capability report for running local LLMs.
# Emits a human-readable summary, then a single line of JSON:
# {os, gpu_vendor, gpu_model, gpu_memory_gib|null, memory_type("dedicated"|"shared"),
#  ram_gib, ram_available_gib, cpu_cores, cpu_physical, cpu_efficient,
#  suggested_backend("vulkan"|"cuda"|"rocm"|"metal"|"cpu"), notes[]}
# Missing optional tools are non-fatal (recorded in notes); only an absent `uname` is fatal.
# JSON output prefers `jq`; falls back to python3 when jq is unavailable.
# bash 3.2-compatible (no mapfile; empty-array expansions are guarded).
set -euo pipefail

# --- OS ---
OS="unknown"
if command -v uname >/dev/null 2>&1; then
    case "$(uname -s)" in
        Linux) OS="linux" ;;
        Darwin) OS="macos" ;;
        MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
        *) OS="$(uname -s)" ;;
    esac
else
    echo '{"os":"unknown","error":"uname unavailable"}' >&2
    exit 1
fi

notes=()
gpu_vendor="unknown"; gpu_model="unknown"; gpu_memory_gib="null"; memory_type="unknown"
ram_gib="null"; ram_available_gib="null"
cpu_cores="null"; cpu_physical="null"; cpu_efficient="null"

# --- GPU vendor + model (collect ALL adapters; prefer discrete) ---
vendor_of() {
    local low; low=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$low" in
        *nvidia*) echo "nvidia" ;;
        *"advanced micro devices"*|*amd*|*radeon*) echo "amd" ;;
        *intel*) echo "intel" ;;
        *apple*|*metal*) echo "apple" ;;
        *) echo "unknown" ;;
    esac
}

gpu_all=()
if [ "$OS" = "linux" ] && command -v lspci >/dev/null 2>&1; then
    while IFS= read -r l; do
        [ -n "$l" ] && gpu_all+=("$l")
    done < <(lspci -nn 2>/dev/null | grep -iE 'vga|3d controller|display controller' || true)
elif [ "$OS" = "macos" ] && command -v system_profiler >/dev/null 2>&1; then
    gl=$(system_profiler SPDisplaysDataType 2>/dev/null | grep -i 'chipset\|model' | head -2 | tr '\n' ' ' || true)
    [ -n "$gl" ] && gpu_all+=("$gl")
fi

# Prefer the discrete GPU: hybrid laptops (Intel iGPU + NVIDIA/AMD dGPU) list the
# iGPU first in lspci, and picking it would misdirect the suggested backend.
gpu_line=""
for want in nvidia amd intel apple unknown; do
    for l in ${gpu_all[@]+"${gpu_all[@]}"}; do
        if [ "$(vendor_of "$l")" = "$want" ]; then gpu_line="$l"; break 2; fi
    done
done

if [ -n "$gpu_line" ]; then
    gpu_model="$gpu_line"
    gpu_vendor=$(vendor_of "$gpu_line")
fi
if [ ${#gpu_all[@]} -gt 1 ]; then
    notes+=("multiple GPU adapters detected ($(printf '%s' "${gpu_all[*]}" | cut -c1-200)) — backend suggestion targets the preferred (discrete) one")
fi

# --- VRAM (dedicated) or shared-memory heap ---
if command -v nvidia-smi >/dev/null 2>&1; then
    mem=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || true)
    if [ -n "$mem" ]; then
        gpu_memory_gib=$(awk -v m="$mem" 'BEGIN{printf "%.1f", m/1024}')
        memory_type="dedicated"
    fi
fi
if [ "$gpu_memory_gib" = "null" ] && command -v vulkaninfo >/dev/null 2>&1; then
    # Some drivers report device-local heap size (bytes) — read it if present.
    vram=$(vulkaninfo --summary 2>/dev/null | grep -iE 'deviceLocalMemorySize|memoryHeaps' | grep -oE '[0-9]+' | head -1 || true)
    if [ -n "$vram" ] && [ "$vram" -gt 0 ]; then
        gpu_memory_gib=$(awk -v v="$vram" 'BEGIN{printf "%.1f", v/1073741824}')
    fi
fi
# NVIDIA dGPU seen but no VRAM read → driver/runtime probably not loaded.
if [ "$gpu_vendor" = "nvidia" ] && [ "$gpu_memory_gib" = "null" ]; then
    notes+=("NVIDIA GPU detected but nvidia-smi returned no memory — driver may not be loaded")
fi

# Contract: memory_type is "dedicated" | "shared". No readable dedicated VRAM
# (iGPU, APU, undetected driver, or no GPU at all) → budget from system RAM.
if [ "$gpu_memory_gib" = "null" ] && [ "$memory_type" = "unknown" ]; then
    memory_type="shared"
    notes+=("no dedicated VRAM detected — budget weights from available system RAM")
fi
if [ "$gpu_memory_gib" != "null" ] && [ "$memory_type" = "unknown" ]; then
    memory_type="dedicated"
fi

# --- RAM ---
if [ "$OS" = "linux" ] && [ -r /proc/meminfo ]; then
    total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    ram_gib=$(awk -v k="$total_kb" 'BEGIN{printf "%.1f", k/1048576}')
    ram_available_gib=$(awk -v k="$avail_kb" 'BEGIN{printf "%.1f", k/1048576}')
elif [ "$OS" = "macos" ] && command -v sysctl >/dev/null 2>&1; then
    total=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    [ "$total" -gt 0 ] && ram_gib=$(awk -v t="$total" 'BEGIN{printf "%.1f", t/1073741824}')
    used=$(sysctl -n hw.memsize 2>/dev/null; vm_stat 2>/dev/null | awk '/Pages occupied/{print $4}' | tr -d '.') 
    # vm_stat reports "Pages occupied by compressor" etc.; fall back to a coarse estimate.
    ram_available_gib=$(awk -v t="${total:-0}" 'BEGIN{printf "%.1f", (t*0.6)/1073741824}')
    notes+=("macOS available RAM is an estimate; run htop/Activity Monitor for exact headroom")
fi

# --- CPU ---
if [ "$OS" = "linux" ] && command -v lscpu >/dev/null 2>&1; then
    cpu_cores=$(lscpu -p 2>/dev/null | { grep -v '^#' || true; } | wc -l | tr -d ' ')
    cpu_physical=$(lscpu -p 2>/dev/null | { grep -v '^#' || true; } | awk -F, '!seen[$2"_"$3]++{c++} END{print c+0}')
    # Efficiency (non-performance) cores = CPUs whose max boost MHz is clearly below the
    # top tier (Intel P/E/LP split). Use EXPLICIT column selection: the default
    # `lscpu -e` column layout varies across util-linux versions/hosts, and
    # hardcoding positions silently yields 0. Same for -p (parse format, comma-sep).
    eff=$(lscpu -p=CPU,ONLINE,MAXMHZ 2>/dev/null | awk -F, '
        /^#/ { next }
        $2 == "yes" {
            mhz = $3 + 0
            if (mhz <= 0) next
            if (mhz > max) max = mhz
            a[++n] = mhz
        }
        END {
            if (max == 0) { print 0; exit }
            thr = max * 0.9; c = 0
            for (i = 1; i <= n; i++) if (a[i] < thr) c++
            print c + 0
        }')
    [ -n "$eff" ] || eff=0
    cpu_efficient="$eff"
    notes+=("cpu_efficient is an estimate from lscpu MAXMHZ tiers; refine P/E split with lscpu -e / cpu topology sysfs")
elif [ "$OS" = "macos" ] && command -v sysctl >/dev/null 2>&1; then
    cpu_cores=$(sysctl -n hw.logicalcpu 2>/dev/null || echo null)
    cpu_physical=$(sysctl -n hw.physicalcpu 2>/dev/null || echo null)
    cpu_efficient=$(sysctl -n hw.perflevel1.logicalcpu 2>/dev/null || echo null)
fi
cpu_cores=${cpu_cores:-0}; cpu_physical=${cpu_physical:-0}; cpu_efficient=${cpu_efficient:-0}

# --- suggested backend ---
suggested_backend="cpu"
case "$gpu_vendor" in
    nvidia) suggested_backend="cuda" ;;
    intel) suggested_backend="vulkan" ;;
    amd) suggested_backend="rocm" ;;
    apple) suggested_backend="metal" ;;
    *) suggested_backend="cpu"; notes+=("no GPU backend matched — falling back to CPU-only") ;;
esac

# --- cross-check with an actual llama-server if present ---
LLAMA_SERVER="${LLAMA_SERVER:-}"
if [ -z "$LLAMA_SERVER" ] && [ -x "$HOME/llama.cpp/build/bin/llama-server" ]; then
    LLAMA_SERVER="$HOME/llama.cpp/build/bin/llama-server"
elif [ -z "$LLAMA_SERVER" ] && command -v llama-server >/dev/null 2>&1; then
    LLAMA_SERVER="$(command -v llama-server)"
fi
if [ -n "$LLAMA_SERVER" ]; then
    devs=$("$LLAMA_SERVER" --list-devices 2>/dev/null | grep -vE '^$' || true)
    if [ -n "$devs" ]; then
        notes+=("llama-server backend sees: $(echo "$devs" | tr '\n' ' ' | cut -c1-160)")
    fi
fi

# --- human summary ---
cat <<EOF
Device report
  OS                $OS
  GPU               $gpu_vendor / $gpu_model
  GPU memory        ${gpu_memory_gib} GiB ($memory_type)
  RAM               ${ram_gib} GiB total, ${ram_available_gib} GiB available
  CPU               $cpu_cores logical / $cpu_physical physical, ~$cpu_efficient eff-bucket cores
  suggested backend $suggested_backend
EOF

# --- JSON (single line; embed notes as JSON array) ---
# jq preferred; python3 fallback keeps the script usable on minimal installs.
if command -v jq >/dev/null 2>&1; then
    jq -nc \
      --arg os "$OS" \
      --arg gpu_vendor "$gpu_vendor" \
      --arg gpu_model "$gpu_model" \
      --argjson gpu_memory_gib "$gpu_memory_gib" \
      --arg memory_type "$memory_type" \
      --argjson ram_gib "$ram_gib" \
      --argjson ram_available_gib "$ram_available_gib" \
      --argjson cpu_cores "$cpu_cores" \
      --argjson cpu_physical "$cpu_physical" \
      --argjson cpu_efficient "$cpu_efficient" \
      --arg suggested_backend "$suggested_backend" \
      --argjson notes "$(jq -cn --arg s "$(printf '%s\n' ${notes[@]+"${notes[@]}"})" '$s | split("\n") | map(select(length > 0))')" \
      '{os:$os, gpu_vendor:$gpu_vendor, gpu_model:$gpu_model, gpu_memory_gib:$gpu_memory_gib,
        memory_type:$memory_type, ram_gib:$ram_gib, ram_available_gib:$ram_available_gib,
        cpu_cores:$cpu_cores, cpu_physical:$cpu_physical, cpu_efficient:$cpu_efficient,
        suggested_backend:$suggested_backend, notes:$notes}'
elif command -v python3 >/dev/null 2>&1; then
    python3 - "$OS" "$gpu_vendor" "$gpu_model" "$gpu_memory_gib" "$memory_type" \
        "$ram_gib" "$ram_available_gib" "$cpu_cores" "$cpu_physical" "$cpu_efficient" \
        "$suggested_backend" "$(printf '%s\n' ${notes[@]+"${notes[@]}"})" <<'PY'
import json, sys

def num(v):
    if v in ("null", ""): return None
    try:
        f = float(v)
        return int(f) if f.is_integer() and "." not in str(v) else f
    except ValueError:
        return v

notes = [s for s in sys.argv[12].split("\n") if s]
gm = sys.argv[4]
print(json.dumps({
    "os": sys.argv[1], "gpu_vendor": sys.argv[2], "gpu_model": sys.argv[3],
    "gpu_memory_gib": None if gm == "null" else float(gm),
    "memory_type": sys.argv[5], "ram_gib": num(sys.argv[6]),
    "ram_available_gib": num(sys.argv[7]), "cpu_cores": num(sys.argv[8]),
    "cpu_physical": num(sys.argv[9]), "cpu_efficient": num(sys.argv[10]),
    "suggested_backend": sys.argv[11], "notes": notes,
}))
PY
else
    echo "detect-device.sh: neither jq nor python3 available — cannot emit JSON" >&2
    exit 1
fi
