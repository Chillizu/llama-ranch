#!/usr/bin/env bash
# recommend-models.sh — live HuggingFace GGUF search with fits hints.
# Usage:
#   recommend-models.sh "<query>" [--ram <gib>] [--ctx <tokens>]
# Stages (the model list is fetched live):
#   1. search        /api/models?search=..&filter=gguf&full=true  → GGUF sibling filenames
#   2. sizes         /api/models/<id>?blobs=true per model         → .gguf file sizes
#   3. KV math       base-model config.json (from base_model: tag) → real n_layer/kv_heads/head_dim
# Then prints a table with a fits hint against --ram (weights + estimated fp16 KV + ~2 GiB buffer).
# Networks that block HF directly: set HF_PROXY (e.g. HF_PROXY=socks5h://127.0.0.1:7891).
# Falls back to a web_search hint if the API is unreachable.
# bash 3.2-compatible (no mapfile) — works on stock macOS.
set -euo pipefail

query="${1:-}"
[ -z "$query" ] && { echo "usage: $0 \"<query>\" [--ram <gib>] [--ctx <tokens>]"; exit 1; }
shift

ram=""; ctx=""
while [ $# -gt 0 ]; do
    case "$1" in
        --ram) ram="$2"; shift 2 ;;
        --ctx) ctx="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

API="https://huggingface.co/api/models"
LIMIT=20
MAX_MODELS=8   # per-model fetch budget (sizes + config)
PROXY="${HF_PROXY:-}"
CURL_ARGS=(-sS --max-time 20)
[ -n "$PROXY" ] && CURL_ARGS+=(--proxy "$PROXY")

if ! command -v curl >/dev/null 2>&1; then
    echo "curl not found — use web_search instead:  ${query} GGUF site:huggingface.co"
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found — use web_search instead:  ${query} GGUF site:huggingface.co"
    exit 0
fi

q=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$query")
url="${API}?search=${q}&filter=gguf&limit=${LIMIT}&full=true"
resp=$(curl "${CURL_ARGS[@]}" "$url" || true)
if [ -z "$resp" ] || ! printf '%s' "$resp" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    echo "HF API unreachable — use web_search instead:  ${query} GGUF"
    exit 0
fi

# Stage 2+3: per distinct model, fetch .gguf sizes and the base model's config for KV math.
# Emit "model_id<TAB>base_model_id" for the first few distinct models.
# (while-read instead of mapfile — bash 3.2 has no mapfile)
idpairs=()
while IFS= read -r pair; do
    [ -n "$pair" ] && idpairs+=("$pair")
done < <(printf '%s' "$resp" | python3 -c '
import json,sys
MAX=int(sys.argv[1])
d=json.load(sys.stdin)
seen=[]
for m in d:
    mid=m.get("id")
    if mid and mid not in seen:
        seen.append(mid)
        base=[t.split(":",1)[1] for t in m.get("tags",[]) if t.startswith("base_model:") and "quantized" not in t]
        print(mid + "\t" + (base[0] if base else ""))
' "$MAX_MODELS")

blobs="{}"   # model_id -> siblings[] (with size)
configs="{}" # model_id -> {"n_layer":..,"n_kv":..,"head_dim":..}
for pair in ${idpairs[@]+"${idpairs[@]}"}; do
    id="${pair%%$'\t'*}"
    base="${pair#*$'\t'}"
    [ "$base" = "$id" ] && base=""

    b=$(curl "${CURL_ARGS[@]}" "${API}/${id}?blobs=true" || true)
    if [ -n "$b" ] && printf '%s' "$b" | python3 -c 'import json,sys;json.load(sys.stdin)' 2>/dev/null; then
        blobs=$(python3 -c '
import json,sys
acc=json.loads(sys.argv[1]); one=json.loads(sys.argv[2])
acc[one.get("id")]=one.get("siblings",[])
print(json.dumps(acc))
' "$blobs" "$b")
    fi

    if [ -n "$base" ]; then
        cfg=$(curl "${CURL_ARGS[@]}" "https://huggingface.co/${base}/raw/main/config.json" 2>/dev/null || true)
        if [ -n "$cfg" ] && printf '%s' "$cfg" | python3 -c 'import json,sys;json.load(sys.stdin)' 2>/dev/null; then
            configs=$(python3 -c '
import json,sys
acc=json.loads(sys.argv[1]); c=json.loads(sys.argv[2])
# some multimodal configs nest the language block under text_config/llm_config
if "num_hidden_layers" not in c:
    for k in ("text_config","llm_config"):
        if k in c: c=c[k]; break
n_layer=c.get("num_hidden_layers"); n_kv=c.get("num_key_value_heads", c.get("num_attention_heads"))
head_dim=c.get("head_dim")
if head_dim is None and c.get("hidden_size") and c.get("num_attention_heads"):
    head_dim=c.get("hidden_size")//c.get("num_attention_heads")
if n_layer and n_kv and head_dim:
    acc[sys.argv[3]]={"n_layer":n_layer,"n_kv":n_kv,"head_dim":head_dim}
print(json.dumps(acc))
' "$configs" "$cfg" "$id")
        fi
    fi
done

python3 - "$ram" "$ctx" "$query" "$resp" "$blobs" "$configs" <<'PY'
import json, re, sys

ram = float(sys.argv[1]) if sys.argv[1] else None
ctx = int(sys.argv[2]) if sys.argv[2] else None
query = sys.argv[3]
resp = json.loads(sys.argv[4])
blobs = json.loads(sys.argv[5])     # id -> siblings[] (with size)
configs = json.loads(sys.argv[6])   # id -> {n_layer,n_kv,head_dim}

QUANT = re.compile(r'\b(I?Q\d+_[A-Za-z0-9]+(?:_[A-Za-z0-9]+)*|BF16|FP16|FP32|F16|F32)\b', re.I)
SPLIT = re.compile(r'-\d{5}-of-\d{5}\.gguf$', re.I)
GB = 1073741824

def kv_bytes_per_token(cfg):
    # KV = 2 * n_layers * n_kv_heads * head_dim * bytes(fp16=2)   (K and V each)
    return 2 * cfg["n_layer"] * cfg["n_kv"] * cfg["head_dim"] * 2

# Key sizes by (repo_id, filename): bare filenames collide across repos
# ("qwen2.5-7b-instruct-q4_k_m.gguf" exists in many), which used to attach
# the wrong repo's size to a row.
by_name = {}
for repo, sibs in blobs.items():
    for s in sibs:
        by_name[(repo, s.get("rfilename"))] = s.get("size")

# Aggregate split GGUFs ("...-00001-of-00003.gguf") into one row per file,
# summing part sizes — large models are usually distributed split.
agg = {}
order = []
for model in resp:
    mid = model.get("id", "")
    for sib in model.get("siblings", []):
        name = sib.get("rfilename", "")
        if not name.lower().endswith(".gguf"):
            continue
        norm = SPLIT.sub('.gguf', name)
        qm = QUANT.search(norm)
        quant = qm.group(1).upper() if qm else "?"
        key = (mid, norm, quant)
        if key not in agg:
            agg[key] = {"size": 0, "have": False, "parts": 0}
            order.append(key)
        size = by_name.get((mid, name))
        if size:
            agg[key]["size"] += size
            agg[key]["have"] = True
        if SPLIT.search(name):
            agg[key]["parts"] += 1

rows = []
seen = set()
for key in order:
    mid, norm, quant = key
    if (mid, quant) in seen:
        continue
    seen.add((mid, quant))
    e = agg[key]
    # Surface split-ness in the quant cell (e.g. "Q8_0 (2p)") — parts are
    # summed into one row, and the underlying filename is never printed.
    qdisp = quant + (" (%dp)" % e["parts"] if e["parts"] else "")
    rows.append((mid, qdisp, e["size"] if e["have"] else None))

if not rows:
    print("No GGUF siblings found for query. Try web_search:  %s GGUF site:huggingface.co" % query)
    sys.exit(0)

hdr = f"{'model':<40} {'quant':<12} {'size_GiB':>9} {'KV_GiB':>8}  fits"
print(hdr); print("-" * len(hdr))
for mid, quant, size_b in rows:
    gib = (size_b / GB) if size_b else None
    cfg = configs.get(mid)
    kv_gib = None
    if cfg:
        kv_gib = kv_bytes_per_token(cfg) * (ctx or 8192) / GB
    if gib is None:
        print(f"{mid[:39]:<40} {quant:<12} {'?':>9} {'?':>8}  -")
        continue
    fits = ""
    if ram is not None:
        if kv_gib is None:
            fits = "unknown"
        else:
            headroom = gib + kv_gib + 2
            fits = "OK" if headroom <= ram else "no"
    kv_display = f"{kv_gib:>8.2f}" if kv_gib is not None else f"{'?':>8}"
    print(f"{mid[:39]:<40} {quant:<12} {gib:>8.1f} {kv_display}  {fits}")
PY
