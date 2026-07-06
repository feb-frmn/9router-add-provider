#!/bin/bash
# add-provider-db.sh — Add a custom provider by injecting directly into 9router's SQLite DB
# Use this when the HTTP API is flaky or 9router dashboard won't load.
#
# 9router uses better-sqlite3 with WAL mode — external writes are picked up on next read.
# The live process holds the DB file open, so writes go through WAL and are visible immediately.
#
# Usage: bash add-provider-db.sh --name "inference" --prefix "inf" --url "https://api.inference.net/v1" --key "sk-xxx"

set -euo pipefail

DB="/var/lib/9router/db/data.sqlite"
NAME=""
PREFIX=""
URL=""
KEY=""
API_TYPE="chat"

while [[ $# -gt 0 ]]; do
  case $1 in
    --name)     NAME="$2";      shift 2 ;;
    --prefix)   PREFIX="$2";    shift 2 ;;
    --url)      URL="$2";       shift 2 ;;
    --key)      KEY="$2";       shift 2 ;;
    --db)       DB="$2";        shift 2 ;;
    --api-type) API_TYPE="$2";  shift 2 ;;
    -h|--help)
      echo "Usage: bash add-provider-db.sh --name NAME --prefix PREFIX --url BASE_URL --key API_KEY"
      echo ""
      echo "Options:"
      echo "  --name      Provider display name"
      echo "  --prefix    Model prefix (e.g. 'inf' → inf/model-name)"
      echo "  --url       Base URL (no /chat/completions)"
      echo "  --key       API key"
      echo "  --db        Path to data.sqlite (default: /var/lib/9router/db/data.sqlite)"
      echo "  --api-type  chat (default) or responses"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$NAME" || -z "$PREFIX" || -z "$URL" || -z "$KEY" ]]; then
  echo "❌ Missing required fields. Need: --name, --prefix, --url, --key"
  exit 1
fi

URL="${URL%/chat/completions}"
URL="${URL%/}"

if [[ ! -f "$DB" ]]; then
  echo "❌ DB not found: $DB"
  echo "   Common locations:"
  echo "     /var/lib/9router/db/data.sqlite"
  echo "     ~/.9router/data.sqlite"
  exit 1
fi

if ! command -v sqlite3 &>/dev/null; then
  echo "❌ sqlite3 not found. Install: sudo apt install sqlite3"
  exit 1
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
NODE_UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
CONN_UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
NODE_ID="openai-compatible-${API_TYPE}-${NODE_UUID}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " DB inject: $NAME ($PREFIX)"
echo " URL: $URL"
echo " DB: $DB"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Sanitize for SQL queries
PREFIX_SQL="${PREFIX//\'/\'\'}"
NAME_SQL="${NAME//\'/\'\'}"
NODE_ID_SQL="${NODE_ID//\'/\'\'}"

# Escape for Python string interpolation
PREFIX_PY="${PREFIX//\'/\\\'}"
NAME_PY="${NAME//\'/\\\'}"
KEY_PY="${KEY//\'/\\\'}"
API_TYPE_PY="${API_TYPE//\'/\\\'}"
URL_PY="${URL//\'/\\\'}"

# Check if node with same prefix already exists
EXISTING=$(sqlite3 "$DB" "SELECT id FROM providerNodes WHERE json_extract(data, '$.prefix')='$PREFIX_SQL' LIMIT 1" 2>/dev/null || echo "")

if [[ -n "$EXISTING" ]]; then
  echo "⚠️  Node with prefix '$PREFIX' already exists: $EXISTING"
  echo "   Adding new connection to existing node..."
  NODE_ID="$EXISTING"
  NODE_ID_SQL="${NODE_ID//\'/\'\'}"
else
  # Create provider node
  NODE_DATA=$(python3 -c "
import json
print(json.dumps({
    'prefix': '$PREFIX_PY',
    'apiType': '$API_TYPE_PY',
    'baseUrl': '$URL_PY',
    'nodeName': '$NAME_PY'
}))
")
  NODE_DATA_SQL="${NODE_DATA//\'/\'\'}"
  echo "✅ Node created: $NODE_ID"
fi

# Create connection
CONN_DATA=$(python3 -c "
import json
print(json.dumps({
    'apiKey': '$KEY_PY',
    'testStatus': 'active',
    'providerSpecificData': {
        'prefix': '$PREFIX_PY',
        'apiType': '$API_TYPE_PY',
        'baseUrl': '$URL_PY',
        'nodeName': '$NAME_PY',
        'connectionProxyEnabled': False,
        'connectionProxyUrl': '',
        'connectionNoProxy': ''
    },
    'backoffLevel': 0
}))
")
CONN_DATA_SQL="${CONN_DATA//\'/\'\'}"

# Wrap inserts in a transaction
SQL_CMDS="BEGIN TRANSACTION;"
if [[ -z "$EXISTING" ]]; then
  SQL_CMDS+="INSERT INTO providerNodes (id, type, name, data, createdAt, updatedAt) VALUES ('$NODE_ID_SQL', 'openai-compatible', '$NAME_SQL', '$NODE_DATA_SQL', '$NOW', '$NOW');"
fi
SQL_CMDS+="INSERT INTO providerConnections (id, provider, authType, name, email, priority, isActive, data, createdAt, updatedAt) VALUES ('$CONN_UUID', '$NODE_ID_SQL', 'apikey', '$NAME_SQL', NULL, 1, 1, '$CONN_DATA_SQL', '$NOW', '$NOW');"
SQL_CMDS+="COMMIT;"
sqlite3 "$DB" "$SQL_CMDS"
echo "✅ Connection created: $CONN_UUID"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✅ Done! Use models as: $PREFIX/<model-name>"
echo " Changes are live immediately (WAL mode)."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
