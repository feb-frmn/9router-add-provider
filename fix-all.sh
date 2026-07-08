#!/bin/bash
# fix-all.sh — Bulk-fix ALL red/unavailable providers in 9router
# Scans all connections, resets error state, clears model locks.
# For B.AI specifically: applies healthy defaults (baseUrl=/v1, defaultModel=glm-5.2)
#
# Usage:
#   bash fix-all.sh                          # fix all unavailable providers
#   bash fix-all.sh --bai                    # fix only B.AI providers
#   bash fix-all.sh --dry-run                # show what would be fixed
#   bash fix-all.sh --db /path/to/data.sqlite

set -euo pipefail

DB="/var/lib/9router/db/data.sqlite"
DRY_RUN=0
BAI_ONLY=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --db)      DB="$2";    shift 2 ;;
    --dry-run) DRY_RUN=1;  shift ;;
    --bai)     BAI_ONLY=1; shift ;;
    -h|--help)
      echo "Fix ALL red/unavailable providers in 9router"
      echo "  bash fix-all.sh"
      echo "  bash fix-all.sh --bai        # fix only B.AI"
      echo "  bash fix-all.sh --dry-run    # preview only"
      exit 0
      ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

DB_PY="${DB//\\'/\\\\\\'}"

python3 << PYEOF
import json, sqlite3, sys
from datetime import datetime, timezone

db = sqlite3.connect('$DB_PY')

# Find ALL broken connections or B.AI specific
if $BAI_ONLY:
    where = """json_extract(data, '$.providerSpecificData.prefix')='bai'
                OR name LIKE 'bai%'
                OR json_extract(data, '$.providerSpecificData.baseUrl') LIKE '%b.ai%'
                OR json_extract(data, '$.providerSpecificData.baseUrl') LIKE '%chat.b.ai%'"""
    print("🔧 Fixing only B.AI connections...")
else:
    where = "json_extract(data, '$.testStatus') = 'unavailable' OR json_extract(data, '$.testStatus') = 'error'"
    print("🔧 Fixing ALL unavailable/error connections...")

rows = db.execute(f"SELECT id, name, provider, data FROM providerConnections WHERE {where}").fetchall()
total = len(rows)
print(f"   Found {total} connection(s) to fix\n")

if total == 0:
    print("✅ Nothing to fix!")
    sys.exit(0)

fixed = 0
for conn_id, name, provider, raw in rows:
    data = json.loads(raw)
    status = data.get('testStatus', '?')
    err = data.get('lastError', '') or ''
    base_url = data.get('providerSpecificData', {}).get('baseUrl', 'N/A')
    prefix = data.get('providerSpecificData', {}).get('prefix', 'N/A')
    
    is_bai = ('b.ai' in base_url or 'bai' in prefix or 'bai' in name.lower())
    
    print(f"  [{conn_id[:12]}...] {name}")
    print(f"    Provider: {provider} | Prefix: {prefix}")
    print(f"    Status: {status} | Error: {err[:70]}")
    print(f"    URL: {base_url}")
    
    if $DRY_RUN:
        print(f"    ⏭️  DRY RUN — would fix\n")
        continue
    
    # Fix baseUrl for B.AI — needs /v1
    if is_bai and '/v1' not in base_url:
        data['providerSpecificData']['baseUrl'] = 'https://api.b.ai/v1'
        print(f"    🔧 URL → https://api.b.ai/v1")
    
    # Set healthy defaults
    data['testStatus'] = 'active'
    data['backoffLevel'] = 0
    for key in ['lastError', 'errorCode', 'lastErrorAt']:
        data.pop(key, None)
    
    # Clear all model locks
    locks = [k for k in data if k.startswith('modelLock_')]
    for k in locks:
        del data[k]
    if locks:
        print(f"    🔓 Cleared {len(locks)} model locks")
    
    # Set default model for B.AI
    if is_bai:
        data['defaultModel'] = 'glm-5.2'
        print(f"    🎯 defaultModel → glm-5.2")
    
    now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')
    db.execute(
        "UPDATE providerConnections SET data=?, isActive=1, updatedAt=? WHERE id=?",
        (json.dumps(data), now, conn_id)
    )
    fixed += 1
    print(f"    ✅ Fixed!\n")

db.commit()
db.close()

print(f"━" * 50)
print(f" ✅ Fixed {fixed}/{total} connections")
print(f"    Refresh dashboard — they should be green now.")
PYEOF
