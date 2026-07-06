#!/bin/bash
# list-providers.sh — Show all providers and their status in 9router
# Usage: bash list-providers.sh [--db /path/to/data.sqlite]

set -euo pipefail

DB="/var/lib/9router/db/data.sqlite"

while [[ $# -gt 0 ]]; do
  case $1 in
    --db) DB="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ ! -f "$DB" ]]; then
  echo "❌ DB not found: $DB"
  exit 1
fi

python3 << PYEOF
import json, sqlite3

db = sqlite3.connect('$DB')

# Built-in providers
rows = db.execute("""
    SELECT name, provider, isActive,
           json_extract(data, '$.testStatus'),
           json_extract(data, '$.errorCode'),
           json_extract(data, '$.backoffLevel')
    FROM providerConnections
    WHERE provider NOT LIKE 'openai-compatible%'
    ORDER BY provider, name
""").fetchall()

print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print(f" {'Built-in Providers':^60}")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print(f" {'Name':<25} {'Provider':<20} {'Status':<12} {'Active'}")
print(f" {'─'*25} {'─'*20} {'─'*12} {'─'*6}")
for name, provider, active, status, err, backoff in rows:
    icon = "✅" if status == "active" else "❌"
    print(f" {icon} {name:<23} {provider:<20} {status or '?':<12} {'yes' if active else 'no'}")

# Custom providers
rows = db.execute("""
    SELECT name, 
           json_extract(data, '$.providerSpecificData.prefix'),
           json_extract(data, '$.providerSpecificData.baseUrl'),
           isActive,
           json_extract(data, '$.testStatus'),
           json_extract(data, '$.errorCode'),
           json_extract(data, '$.backoffLevel'),
           json_extract(data, '$.lastError')
    FROM providerConnections
    WHERE provider LIKE 'openai-compatible%'
    ORDER BY name
""").fetchall()

print()
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print(f" {'Custom Providers (OpenAI-compatible)':^60}")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print(f" {'Name':<15} {'Prefix':<10} {'URL':<40} {'Status':<10} {'Err'}")
print(f" {'─'*15} {'─'*10} {'─'*40} {'─'*10} {'─'*5}")
for name, prefix, url, active, status, err, backoff, last_err in rows:
    icon = "✅" if status == "active" else "❌"
    url_short = (url[:37] + "...") if url and len(url) > 40 else (url or "?")
    print(f" {icon} {name:<13} {prefix or '?':<10} {url_short:<40} {status or '?':<10} {err or '-'}")

# Summary
total_custom = len(rows)
total = db.execute("SELECT COUNT(*) FROM providerConnections").fetchone()[0]
active = db.execute("SELECT COUNT(*) FROM providerConnections WHERE isActive=1 AND json_extract(data, '$.testStatus')='active'").fetchone()[0]
print()
print(f" Total: {total} connections ({active} active, {total_custom} custom)")

db.close()
PYEOF
