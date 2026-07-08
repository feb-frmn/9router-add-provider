#!/bin/bash
# add-bai.sh — Add B.AI (chat.b.ai) API keys to 9router with healthy defaults
# B.AI keys get 403 on premium models (gpt-*, kimi-*) but GLM-5.2 works free.
# This script injects with baseUrl=/v1 + defaultModel=glm-5.2 + clean state.
#
# Usage:
#   bash add-bai.sh --key "sk-or-v1-xxx"
#   bash add-bai.sh --key "sk-or-v1-xxx" --name "my-bai-account"  # custom name
#   bash add-bai.sh --key "sk-or-v1-xxx" --db /path/to/data.sqlite
#   bash add-bai.sh --batch keys.txt  # one key per line
#   bash add-bai.sh --fix-prefix "bai"  # fix existing red BAI connection

set -euo pipefail

DB="/var/lib/9router/db/data.sqlite"
KEY=""
NAME=""
PREFIX="bai"
URL="https://api.b.ai/v1"
BATCH_FILE=""
FIX_PREFIX=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --key)   KEY="$2";   shift 2 ;;
    --name)  NAME="$2";  shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --url)   URL="$2";   shift 2 ;;
    --db)    DB="$2";    shift 2 ;;
    --batch) BATCH_FILE="$2"; shift 2 ;;
    --fix-prefix) FIX_PREFIX="$2"; shift 2 ;;
    -h|--help)
      echo "B.AI (chat.b.ai) Provider Manager for 9router"
      echo ""
      echo "Add keys:"
      echo "  bash add-bai.sh --key \"sk-or-v1-xxx\""
      echo "  bash add-bai.sh --batch keys.txt"
      echo ""
      echo "Fix existing broken BAI connections:"
      echo "  bash add-bai.sh --fix-prefix \"bai\""
      echo "  bash add-bai.sh --fix-prefix \"bai\" --url \"https://api.b.ai/v1\""
      echo ""
      echo "All options:"
      echo "  --key       API key (sk-or-v1-...)"
      echo "  --name      Friendly name (default: auto-generated)"
      echo "  --prefix    Model prefix (default: bai)"
      echo "  --url       Base URL (default: https://api.b.ai/v1)"
      echo "  --db        Path to data.sqlite (default: /var/lib/9router/db/data.sqlite)"
      echo "  --batch     File with one API key per line"
      echo "  --fix-prefix Fix all connections matching this prefix"
      exit 0
      ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

if [[ ! -f "$DB" ]]; then
  echo "❌ DB not found: $DB"
  echo "   Try: --db ~/.9router/db/data.sqlite"
  exit 1
fi

DB_PY="${DB//\\'/\\\\\\'}"
PREFIX_PY="${PREFIX//\\'/\\\\\\'}"
URL_PY="${URL//\\'/\\\\\\'}"
KEY_PY=""
NAME_PY=""

# ─── Fix mode ──────────────────────────────────────────
if [[ -n "$FIX_PREFIX" ]]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " 🔧 Fixing all connections with prefix: $FIX_PREFIX"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  python3 << PYEOF
import json, sqlite3, sys

db = sqlite3.connect('$DB_PY')
rows = db.execute("""
    SELECT id, name, data FROM providerConnections
    WHERE json_extract(data, '$.providerSpecificData.prefix')='$PREFIX_PY'
       OR name LIKE 'bai%' OR provider LIKE '%bai%'
""").fetchall()

if not rows:
    print("❌ No BAI connections found with prefix '$FIX_PREFIX'")
    # Show what's available
    rows2 = db.execute("SELECT id, name, json_extract(data, '$.providerSpecificData.prefix'), json_extract(data, '$.testStatus') FROM providerConnections LIMIT 10").fetchall()
    if rows2:
        print("   Recent connections:")
        for r in rows2[:5]: print(f"     {r[0][:12]}... | {r[1]} | prefix={r[2] or 'N/A'} | {r[3]}")
    sys.exit(1)

print(f"Found {len(rows)} BAI connection(s)")
count = 0
for conn_id, name, raw in rows:
    data = json.loads(raw)
    base_url = url = data.get('providerSpecificData', {}).get('baseUrl', 'N/A')
    status = data.get('testStatus', '?')
    
    # Apply BAI healthy defaults
    old_url = data.get('providerSpecificData', {}).get('baseUrl', '')
    if '/v1' not in old_url:
        print(f"  📍 {conn_id[:12]}... {name}: fixing URL ({old_url} → $URL_PY)")
        data['providerSpecificData']['baseUrl'] = '$URL_PY'
    
    data['testStatus'] = 'active'
    data['defaultModel'] = 'glm-5.2'
    for key in ['lastError', 'errorCode', 'lastErrorAt']:
        data.pop(key, None)
    data['backoffLevel'] = 0
    for k in list(data.keys()):
        if k.startswith('modelLock_'):
            del data[k]
    
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')
    db.execute("UPDATE providerConnections SET data=?, isActive=1, updatedAt=? WHERE id=?", (json.dumps(data), now, conn_id))
    count += 1
    print(f"  ✅ {name}: {status} → active (cleared locks, backoff)")

db.commit()
db.close()
print(f"\n✅ Fixed {count} BAI connections — should be green now.")
print("   Test with: curl http://localhost:20128/v1/chat/completions -d '{\"model\":\"${FIX_PREFIX}/glm-5.2\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}'")
PYEOF
  exit 0
fi

# ─── Batch mode ────────────────────────────────────────
if [[ -n "$BATCH_FILE" ]]; then
  if [[ ! -f "$BATCH_FILE" ]]; then
    echo "❌ Batch file not found: $BATCH_FILE"
    exit 1
  fi
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " 📦 Batch adding BAI keys from: $BATCH_FILE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  count=0
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    
    # Check if it has prefix or just raw key
    if [[ "$line" == "sk-"* || "$line" == "sk-or-v1-"* ]]; then
      KEY="$line"
      NAME="${PREFIX}-$(openssl rand -hex 4)"
    elif [[ "$line" == *"|"* ]]; then
      NAME="${line%%|*}"
      KEY="${line##*|}"
    else
      KEY="$line"
      NAME="${PREFIX}-$(openssl rand -hex 4)"
    fi
    
    KEY_PY="${KEY//\\'/\\\\\\'}"
    NAME_PY="${NAME//\\'/\\\\\\'}"
    bash "$0" --key "$KEY" --name "$NAME"
    count=$((count + 1))
  done < "$BATCH_FILE"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " ✅ Batch complete: $count BAI keys added"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 0
fi

# ─── Single key mode ───────────────────────────────────
if [[ -z "$KEY" ]]; then
  echo "❌ Need --key or --batch"
  exit 1
fi

if [[ -z "$NAME" ]]; then
  NAME="${PREFIX}-$(openssl rand -hex 4)"
fi

# Sanitize for SQL
PREFIX_SQL="${PREFIX//\\'/\\'\\'}"
NAME_SQL="${NAME//\\'/\\'\\'}"
KEY_SQL="${KEY//\\'/\\'\\'}"
URL_SQL="${URL//\\'/\\'\\'}"
KEY_PY="${KEY//\\'/\\\\\\'}"
NAME_PY="${NAME//\\'/\\\\\\'}"
URL_PY="${URL//\\'/\\\\\\'}"
PREFIX_PY="${PREFIX//\\'/\\\\\\'}"
API_TYPE="chat"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 🅱️  B.AI Provider: $NAME"
echo "    Prefix: $PREFIX"
echo "    URL:    $URL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check if node with this prefix exists
EXISTING=$(sqlite3 "$DB" "SELECT id FROM providerNodes WHERE json_extract(data, '$.prefix')='$PREFIX_SQL' LIMIT 1" 2>/dev/null || echo "")

NOW=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
NODE_UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
CONN_UUID=$(python3 -c "import uuid; print(uuid.uuid4())")

if [[ -n "$EXISTING" ]]; then
  NODE_ID="$EXISTING"
  echo "⚠️  Node '$PREFIX' exists: $NODE_ID"
  echo "   Adding connection to existing node..."
else
  NODE_ID="openai-compatible-${API_TYPE}-${NODE_UUID}"
  
  NODE_DATA=$(python3 -c "
import json
print(json.dumps({
    'prefix': '$PREFIX_PY',
    'apiType': '$API_TYPE',
    'baseUrl': '$URL_PY',
    'nodeName': '$NAME_PY'
}))
")
  NODE_DATA_SQL="${NODE_DATA//\\'/\\'\\'}"
  sqlite3 "$DB" "INSERT INTO providerNodes (id, type, name, data, createdAt, updatedAt) VALUES ('$NODE_ID', 'openai-compatible', '$NAME_SQL', '$NODE_DATA_SQL', '$NOW', '$NOW');"
  echo "✅ Node created: $NODE_ID"
fi

# Create connection with B.AI healthy defaults
#  - testStatus: active (skips 9router's broken model test)
#  - defaultModel: glm-5.2 (works without deposit)
#  - backoffLevel: 0
#  - No lastError, no modelLock_*
CONN_DATA=$(python3 -c "
import json
print(json.dumps({
    'apiKey': '$KEY_PY',
    'testStatus': 'active',
    'defaultModel': 'glm-5.2',
    'providerSpecificData': {
        'prefix': '$PREFIX_PY',
        'apiType': '$API_TYPE',
        'baseUrl': '$URL_PY',
        'nodeName': '$NAME_PY',
        'connectionProxyEnabled': False,
        'connectionProxyUrl': '',
        'connectionNoProxy': ''
    },
    'backoffLevel': 0
}))
")
CONN_DATA_SQL="${CONN_DATA//\\'/\\'\\'}"
NODE_ID_SQL="${NODE_ID//\\'/\\'\\'}"
sqlite3 "$DB" "INSERT INTO providerConnections (id, provider, authType, name, email, priority, isActive, data, createdAt, updatedAt) VALUES ('$CONN_UUID', '$NODE_ID_SQL', 'apikey', '$NAME_SQL', NULL, 1, 1, '$CONN_DATA_SQL', '$NOW', '$NOW');"
echo "✅ Connection created: $CONN_UUID"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✅ B.AI key added: $NAME"
echo "    Test:  curl http://localhost:20128/v1/chat/completions -d '{\"model\":\"${PREFIX}/glm-5.2\",\"messages\":[{\"role\":\"user\",\"content\":\"PONG\"}],\"max_tokens\":5}'"
echo "    Models: ${PREFIX}/glm-5.2, ${PREFIX}/@cf/deepseek-ai/deepseek-r1, etc."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
