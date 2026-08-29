#!/usr/bin/env bash
# detect-device.sh — one-shot device capability report for running local LLMs.
# Emits a human-readable summary, then a single line of JSON:
# {os, gpu_vendor, gpu_model, gpu_memory_gib|null, memory_type("dedicated"|"shared"),
#  ram_gib, ram_available_gib, cpu_cores, cpu_physical, cpu_efficient,
#  suggested_backend("vulkan"|"cuda"|"rocm"|"metal"|"cpu"), notes[]}
# Missing optional tools are non-fatal (recorded in notes); only an absent `uname` is fatal.
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

# --- GPU vendor + model ---
gpu_line=""
if [ "$OS" = "linux" ] && command -v lspci >/dev/null 2>&1; then
    gpu_line=$(lspci -nn 2>/dev/null | grep -iE 'vga|3d controller|display controller' | head -1 || true)
elif [ "$OS" = "macos" ] && command -v system_profiler >/dev/null 2>&1; then
    gpu_line=$(system_profiler SPDisplaysDataType 2>/dev/null | grep -i 'chipset\|model' | head -2 | tr '\n' ' ' || true)
fi

if [ -n "$gpu_line" ]; then
    gpu_model="$gpu_line"
    low=$(printf '%s' "$gpu_line" | tr '[:upper:]' '[:lower:]')
    case "$low" in
        *nvidia*) gpu_vendor="nvidia" ;;
        *"advanced micro devices"*|*amd*|*radeon*) gpu_vendor="amd" ;;
        *intel*) gpu_vendor="intel" ;;
        *apple*|*metal*) gpu_vendor="apple" ;;
        *) gpu_vendor="unknown" ;;
    esac
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
# Intel integrated/Arc shared heap: lspci says "Memory size" only for dGPUs; treat as shared.
if [ "$gpu_memory_gib" = "null" ] && [ "$gpu_vendor" = "intel" ]; then
    memory_type="shared"
    notes+=("integrated/shared-memory GPU: weights live in system RAM's shared heap — budget with available RAM, not nominal total")
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
    cpu_cores=$(lscpu -p 2>/dev/null | grep -v '^#' | wc -l)
    cpu_physical=$(lscpu -p 2>/dev/null | grep -v '^#' | awk -F, '!seen[$2]++{c++} END{print c}')
    # Efficiency (non-performance) cores = CPUs whose max boost MHz is clearly below the
    # top tier (Intel P/E/LP split). lscpu -e columns: CPU NODE SOCKET CORE L1d:.. ONLINE MAXMHZ MINMHZ MHZ.
    eff=$(lscpu -e 2>/dev/null | awk '
        NR>1 {
            if ($6 != "yes") next
            mhz=$7+0
            if (mhz<=0) next
            if (mhz>max) max=mhz
            a[NR]=mhz
        }
        END {
            if (max==0) { print 0; exit }
            thr=max*0.9; c=0
            for (i in a) if (a[i]<thr) c++
            print c+0
        }')
    cpu_efficient="$eff"
    notes+=("cpu_efficient is an estimate from lscpu -e max-MHz tiers; refine P/E split with lscpu -e / cpu topology sysfs")
elif [ "$OS" = "macos" ] && command -v sysctl >/dev/null 2>&1; then
    cpu_cores=$(sysctl -n hw.logicalcpu 2>/dev/null || echo null)
    cpu_physical=$(sysctl -n hw.physicalcpu 2>/dev/null || echo null)
    cpu_efficient=$(sysctl -n hw.perflevel1.logicalcpu 2>/dev/null || echo null)
fi

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
  --argjson notes "$(jq -cn --arg s "$(printf '%s\n' "${notes[@]}")" '$s | split("\n") | map(select(length > 0))')" \
  '{os:$os, gpu_vendor:$gpu_vendor, gpu_model:$gpu_model, gpu_memory_gib:$gpu_memory_gib,
    memory_type:$memory_type, ram_gib:$ram_gib, ram_available_gib:$ram_available_gib,
    cpu_cores:$cpu_cores, cpu_physical:$cpu_physical, cpu_efficient:$cpu_efficient,
    suggested_backend:$suggested_backend, notes:$notes}'
