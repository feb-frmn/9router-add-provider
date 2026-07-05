#!/bin/bash
# add-provider.sh — Add a custom OpenAI-compatible provider to 9router
# Usage: bash add-provider.sh --name "inference" --prefix "inf" --url "https://api.inference.net/v1" --key "sk-xxx"
# Or:    bash add-provider.sh --config examples/inference-net.env

set -euo pipefail

HOST="localhost:20128"
NAME=""
PREFIX=""
URL=""
KEY=""
API_TYPE="chat"
TYPE="openai-compatible"
CONFIG_FILE=""

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --name)    NAME="$2";     shift 2 ;;
    --prefix)  PREFIX="$2";   shift 2 ;;
    --url)     URL="$2";      shift 2 ;;
    --key)     KEY="$2";      shift 2 ;;
    --host)    HOST="$2";     shift 2 ;;
    --type)    TYPE="$2";     shift 2 ;;
    --api-type) API_TYPE="$2"; shift 2 ;;
    --config)  CONFIG_FILE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: bash add-provider.sh --name NAME --prefix PREFIX --url BASE_URL --key API_KEY"
      echo ""
      echo "Options:"
      echo "  --name      Provider display name (e.g. 'inference')"
      echo "  --prefix    Model prefix (e.g. 'inf' → use as inf/model-name)"
      echo "  --url       Base URL without /chat/completions (e.g. 'https://api.inference.net/v1')"
      echo "  --key       API key"
      echo "  --host      9router host:port (default: localhost:20128)"
      echo "  --type      Provider type: openai-compatible (default), anthropic-compatible, custom-embedding"
      echo "  --api-type  API type: chat (default), responses"
      echo "  --config    Load settings from .env file instead of flags"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Load config file if provided
if [[ -n "$CONFIG_FILE" ]]; then
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ Config file not found: $CONFIG_FILE"
    exit 1
  fi
  source "$CONFIG_FILE"
fi

# Validate
if [[ -z "$NAME" || -z "$PREFIX" || -z "$URL" || -z "$KEY" ]]; then
  echo "❌ Missing required fields. Need: --name, --prefix, --url, --key"
  echo "   Run with --help for usage."
  exit 1
fi

# Strip trailing /chat/completions if someone pastes the full URL
URL="${URL%/chat/completions}"
URL="${URL%/}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Adding provider: $NAME"
echo " Prefix: $PREFIX"
echo " URL: $URL"
echo " Host: $HOST"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Health check
HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://$HOST/api/health" 2>/dev/null || echo "000")
if [[ "$HTTP" != "200" ]]; then
  echo "❌ 9router not reachable at http://$HOST (HTTP $HTTP)"
  echo "   Make sure 9router is running on port ${HOST##*:}"
  exit 1
fi
echo "✅ 9router is running"

# Step 1 — Create provider node
echo ""
echo "[1/3] Creating provider node..."

NODE_JSON=$(curl -s -X POST "http://$HOST/api/provider-nodes" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"$NAME\",
    \"prefix\": \"$PREFIX\",
    \"apiType\": \"$API_TYPE\",
    \"baseUrl\": \"$URL\",
    \"type\": \"$TYPE\"
  }" 2>/dev/null)

# Extract node ID
NODE_ID=$(echo "$NODE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['node']['id'])" 2>/dev/null)

if [[ -z "$NODE_ID" ]]; then
  # Maybe node already exists — try to find it
  echo "   ⚠️  Node creation failed (might already exist). Searching..."
  NODE_ID=$(curl -s "http://$HOST/api/provider-nodes" 2>/dev/null | \
    python3 -c "
import json, sys
nodes = json.load(sys.stdin).get('nodes', [])
for n in nodes:
  if n.get('prefix') == '$PREFIX' or n.get('name') == '$NAME':
    print(n['id'])
    break
" 2>/dev/null)

  if [[ -z "$NODE_ID" ]]; then
    echo "❌ Failed to create or find node."
    echo "   Response: $NODE_JSON"
    exit 1
  fi
  echo "   Found existing node: $NODE_ID"
else
  echo "   ✅ Node created: $NODE_ID"
fi

# Step 2 — Attach API key
echo ""
echo "[2/3] Attaching API key..."

CONN_JSON=$(curl -s -X POST "http://$HOST/api/providers" \
  -H "Content-Type: application/json" \
  -d "{
    \"provider\": \"$NODE_ID\",
    \"name\": \"$NAME\",
    \"apiKey\": \"$KEY\"
  }" 2>/dev/null)

CONN_ID=$(echo "$CONN_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('connection',{}).get('id',''))" 2>/dev/null)

if [[ -z "$CONN_ID" ]]; then
  echo "⚠️  Key attach response: $CONN_JSON"
  echo "   (might be ok if connection already exists)"
else
  echo "   ✅ Connection created: $CONN_ID"
fi

# Step 3 — Discover available models
echo ""
echo "[3/3] Discovering available models..."

MODELS_JSON=$(curl -s -m 30 "$URL/models" -H "Authorization: Bearer $KEY" 2>/dev/null || echo "{}")
MODEL_LIST=$(echo "$MODELS_JSON" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    models = d.get('data', [])
    if models:
        print(f'Found {len(models)} models:')
        for m in models:
            mid = m.get('id','')
            print(f'  → {mid}')
    else:
        print('NO_MODELS')
except:
    print('NO_MODELS')
" 2>/dev/null)

if [[ "$MODEL_LIST" == "NO_MODELS" ]]; then
  echo "   ⚠️  Could not list models (some providers don't expose /models)."
  echo "   Check the provider docs for available model names."
else
  echo "   $MODEL_LIST"

  # Auto-test first non-meta model (skip 'auto', 'router', audio/image models)
  FIRST_MODEL=$(echo "$MODELS_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
skip = {'auto', 'step-router-v1'}
skip_prefix = ('stepaudio', 'step-image')
for m in d.get('data', []):
    mid = m.get('id','')
    if mid in skip or any(mid.startswith(p) for p in skip_prefix):
        continue
    print(mid)
    break
" 2>/dev/null)

  if [[ -n "$FIRST_MODEL" ]]; then
    echo ""
    echo "   Testing $PREFIX/$FIRST_MODEL..."
    RESP=$(curl -s -m 30 "http://$HOST/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d "{
        \"model\": \"$PREFIX/$FIRST_MODEL\",
        \"messages\": [{\"role\":\"user\",\"content\":\"reply with exactly: PONG\"}],
        \"max_tokens\": 10
      }" 2>/dev/null || echo "{}")

    if echo "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'choices' in d" 2>/dev/null; then
      echo "   ✅ $PREFIX/$FIRST_MODEL works!"
    else
      ERR=$(echo "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error',{}).get('message','unknown error')[:100])" 2>/dev/null || echo "timeout or no response")
      echo "   ⚠️  Test: $ERR"
      echo "   Provider is added — try other models manually."
    fi
  fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✅ Done! Use models as: $PREFIX/<model-name>"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
exit 0
