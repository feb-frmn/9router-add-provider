#!/bin/bash
# fix-provider.sh — Fix a broken/red provider in 9router
# Clears error state, model locks, and backoff level so it retries immediately.
#
# Usage:
#   bash fix-provider.sh --prefix "inf"
#   bash fix-provider.sh --id "7fbad63f-002a-4c99-8c5a-0461482abaa8"
#   bash fix-provider.sh --prefix "inf" --url "https://api.inference.net/v1"  # also fix baseUrl

set -euo pipefail

DB="/var/lib/9router/db/data.sqlite"
PREFIX=""
CONN_ID=""
NEW_URL=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --prefix)  PREFIX="$2";  shift 2 ;;
    --id)      CONN_ID="$2"; shift 2 ;;
    --url)     NEW_URL="$2"; shift 2 ;;
    --db)      DB="$2";      shift 2 ;;
    -h|--help)
      echo "Usage: bash fix-provider.sh --prefix PREFIX [--url NEW_BASE_URL]"
      echo "   or: bash fix-provider.sh --id CONNECTION_ID [--url NEW_BASE_URL]"
      echo ""
      echo "Clears: error state, all model locks, backoff level"
      echo "Optionally fixes the base URL if it was wrong."
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$PREFIX" && -z "$CONN_ID" ]]; then
  echo "❌ Need --prefix or --id"
  exit 1
fi

if [[ ! -f "$DB" ]]; then
  echo "❌ DB not found: $DB"
  exit 1
fi

# Sanitize for SQL queries
PREFIX_SQL="${PREFIX//\'/\'\'}"

# Find connection
if [[ -n "$PREFIX" ]]; then
  CONN_ID=$(sqlite3 "$DB" "SELECT id FROM providerConnections WHERE json_extract(data, '$.providerSpecificData.prefix')='$PREFIX_SQL' LIMIT 1" 2>/dev/null)
fi

if [[ -z "$CONN_ID" ]]; then
  echo "❌ Connection not found for prefix '$PREFIX'"
  echo "   Available prefixes:"
  sqlite3 "$DB" "SELECT json_extract(data, '$.providerSpecificData.prefix'), name, json_extract(data, '$.testStatus') FROM providerConnections WHERE provider LIKE 'openai-compatible%'" 2>/dev/null
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Fixing connection: $CONN_ID"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Escape single quotes for Python string interpolation
DB_PY="${DB//\'/\\\'}"
CONN_ID_PY="${CONN_ID//\'/\\\'}"
NEW_URL_PY="${NEW_URL//\'/\\\'}"

# Get current data and fix it
python3 << PYEOF
import json, sqlite3

db = sqlite3.connect('$DB_PY')
row = db.execute("SELECT data, name FROM providerConnections WHERE id=?", ('$CONN_ID_PY',)).fetchone()
if not row:
    print("❌ Connection not found")
    exit(1)

data = json.loads(row[0])
name = row[1]
print(f"   Provider: {name}")
print(f"   Status: {data.get('testStatus', '?')} (error: {data.get('errorCode', 'none')})")
print(f"   Backoff: {data.get('backoffLevel', 0)}")

# Fix baseUrl if requested
new_url = '$NEW_URL_PY'
if new_url:
    old_url = data.get('providerSpecificData', {}).get('baseUrl', '')
    data['providerSpecificData']['baseUrl'] = new_url
    print(f"   URL: {old_url} → {new_url}")

# Clear error state
data['testStatus'] = 'active'
for key in ['lastError', 'errorCode', 'lastErrorAt']:
    data.pop(key, None)
data['backoffLevel'] = 0

# Clear all model locks
locks = [k for k in data if k.startswith('modelLock_')]
for k in locks:
    del data[k]
print(f"   Cleared {len(locks)} model locks")

# Update
from datetime import datetime, timezone
now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')
db.execute(
    "UPDATE providerConnections SET data=?, isActive=1, updatedAt=? WHERE id=?",
    (json.dumps(data), now, '$CONN_ID_PY')
)
db.commit()
db.close()
print("   ✅ Fixed!")
PYEOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✅ Provider reset. Check dashboard — should be green now."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
