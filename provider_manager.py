#!/usr/bin/env python3
"""
9router Universal Provider Manager v2.1
Add, fix, bulk-import ANY provider via direct DB injection.
Works with 9router v0.5.8+ (tested on v0.5.20)

Usage:
  # Add a provider
  python3 provider-manager.py add --name "bai" --prefix "bai" --url "https://api.b.ai/v1" --key "sk-xxx"
  
  # Add B.AI with healthy defaults
  python3 provider-manager.py add-bai --key "sk-xxx"
  
  # Bulk import from file
  python3 provider-manager.py bulk --file keys.txt
  
  # List all providers
  python3 provider-manager.py list
  
  # Fix broken providers
  python3 provider-manager.py fix --prefix "bai"
  python3 provider-manager.py fix-all

  # Test a model
  python3 provider-manager.py test --model "bai/glm-5.2"
"""

import json, sqlite3, os, sys, uuid, re, argparse, datetime, secrets

# ─── Config ─────────────────────────────────────────────
DB = os.environ.get("ROUTER_DB", "/var/lib/9router/db/data.sqlite")
ROUTER_HOST = os.environ.get("ROUTER_HOST", "http://localhost:20128")

# ⚠️ 9router v0.5.20 only! Older versions use sql.js (in-memory)
# The DB path changed in v0.5.20 to file-based better-sqlite3 at /var/lib/9router/db/data.sqlite
REQUIRED_VERSION = "0.5.20"

# ─── B.AI healthy defaults ──────────────────────────────
BAI_DEFAULTS = {
    "baseUrl": "https://api.b.ai/v1",
    "defaultModel": "glm-5.2",
    "prefix": "bai",
    "apiType": "chat"
}

# ─── Provider type configs ──────────────────────────────
# Each provider type has known working defaults
PROVIDER_TEMPLATES = {
    "openai": {
        "baseUrl": "https://api.openai.com/v1",
        "prefix": "openai",
        "apiType": "chat"
    },
    "bai": {
        "baseUrl": "https://api.b.ai/v1",
        "prefix": "bai",
        "apiType": "chat",
        "defaultModel": "glm-5.2"
    },
    "cf": {
        "builtin": True,
        "providerId": "cloudflare-ai",
        "prefix": "cf",
        "note": "Use built-in provider. providerSpecificData needs accountId"
    },
    "iamhc": {
        "baseUrl": "https://api.iamhc.cn/v1",
        "prefix": "iamhc",
        "apiType": "chat"
    },
    "inference": {
        "baseUrl": "https://api.inference.net/v1",
        "prefix": "inf",
        "apiType": "chat"
    },
    "antigravity": {
        "builtin": True,
        "providerId": "antigravity",
        "prefix": "ag",
        "note": "Use built-in OAuth provider. Requires browser login."
    },
    "custom": {
        "baseUrl": "",
        "prefix": "custom",
        "apiType": "chat"
    }
}


def get_db():
    if not os.path.exists(DB):
        print(f"❌ DB not found: {DB}")
        print(f"   Set ROUTER_DB env or check path")
        print(f"   Default for v0.5.20: /var/lib/9router/db/data.sqlite")
        print(f"   Default for older: ~/.9router/db/data.sqlite")
        sys.exit(1)
    return sqlite3.connect(DB)


def get_provider_type(args):
    """Detect provider type from args or name"""
    name = (args.name or args.prefix or "").lower()
    url = (args.url or "").lower()
    key = (args.api_key or "").lower()
    
    if args.type and args.type in PROVIDER_TEMPLATES:
        return args.type
    
    if url and 'b.ai' in url: return 'bai'
    if url and 'cloudflare' in url: return 'cf'
    if url and 'iamhc' in url: return 'iamhc'
    if url and 'inference' in url: return 'inference'
    if url and 'openai' in url: return 'openai'
    if key and key.startswith('sk-or-v'): return 'bai'
    if key and key.startswith('cfut_'): return 'cf'
    
    return 'custom'


def create_healthy_connection(name, prefix, url, api_key, api_type="chat", default_model=None):
    """Create connection data with healthy defaults (no model locks, active status)"""
    data = {
        "apiKey": api_key,
        "testStatus": "active",
        "backoffLevel": 0,
        "providerSpecificData": {
            "prefix": prefix,
            "apiType": api_type,
            "baseUrl": url,
            "nodeName": name,
            "connectionProxyEnabled": False,
            "connectionProxyUrl": "",
            "connectionNoProxy": ""
        }
    }
    if default_model:
        data["defaultModel"] = default_model
    return data


def find_or_create_node(db, prefix, url, api_type="chat", name=None):
    """Find existing provider node or create new one"""
    node = db.execute(
        "SELECT id, name FROM providerNodes WHERE json_extract(data, '$.prefix')=? LIMIT 1",
        (prefix,)
    ).fetchone()
    
    if node:
        return node[0], node[1], False
    
    node_id = f"openai-compatible-{api_type}-{uuid.uuid4()}"
    now = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S.000Z')
    node_name = name or prefix
    node_data = json.dumps({
        "prefix": prefix,
        "apiType": api_type,
        "baseUrl": url,
        "nodeName": node_name
    })
    
    db.execute(
        "INSERT INTO providerNodes (id, type, name, data, createdAt, updatedAt) VALUES (?, 'openai-compatible', ?, ?, ?, ?)",
        (node_id, node_name, node_data, now, now)
    )
    return node_id, node_name, True


def add_provider(db, name, prefix, url, api_key, api_type="chat", default_model=None):
    """Add or update a provider connection"""
    node_id, node_name, is_new = find_or_create_node(db, prefix, url, api_type, name)
    now = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S.000Z')
    conn_id = str(uuid.uuid4())
    conn_name = name or f"{prefix}-{secrets.token_hex(4)}"
    
    conn_data = create_healthy_connection(conn_name, prefix, url, api_key, api_type, default_model)
    
    db.execute(
        "INSERT INTO providerConnections (id, provider, authType, name, email, priority, isActive, data, createdAt, updatedAt) VALUES (?, ?, 'apikey', ?, NULL, 1, 1, ?, ?, ?)",
        (conn_id, node_id, conn_name, json.dumps(conn_data), now, now)
    )
    db.commit()
    
    return {
        "connection_id": conn_id,
        "node_id": node_id,
        "name": conn_name,
        "node_created": is_new
    }


def add_bai_provider(db, api_key, name=None):
    """Add B.AI provider with healthy defaults"""
    prefix = BAI_DEFAULTS["prefix"]
    url = BAI_DEFAULTS["baseUrl"]
    def_model = BAI_DEFAULTS["defaultModel"]
    api_type = BAI_DEFAULTS["apiType"]
    name = name or f"bai-{secrets.token_hex(4)}"
    
    return add_provider(db, name, prefix, url, api_key, api_type, def_model)


def list_providers(db):
    """List all provider connections with status"""
    rows = db.execute("""
        SELECT pc.id, pc.name, pc.provider, pc.isActive,
               json_extract(pc.data, '$.testStatus') as status,
               json_extract(pc.data, '$.errorCode') as err,
               json_extract(pc.data, '$.providerSpecificData.prefix') as prefix,
               json_extract(pc.data, '$.providerSpecificData.baseUrl') as url,
               json_extract(pc.data, '$.backoffLevel') as backoff,
               json_extract(pc.data, '$.defaultModel') as defModel,
               pn.name as node_name
        FROM providerConnections pc
        LEFT JOIN providerNodes pn ON pc.provider = pn.id
        ORDER BY pc.createdAt DESC
    """).fetchall()
    
    return [
        {
            "id": r[0][:12], "name": r[1], "provider": r[2], "active": r[3],
            "status": r[4] or "?", "error": r[5], "prefix": r[6] or "?",
            "url": r[7] or "?", "backoff": r[8] or 0, "default_model": r[9] or "?",
            "node": r[10] or "?"
        }
        for r in rows
    ]


def fix_provider(db, conn_id=None, prefix=None):
    """Fix a broken/red provider connection"""
    if conn_id:
        rows = db.execute("SELECT id, name, data FROM providerConnections WHERE id=?", (conn_id,)).fetchall()
    elif prefix:
        rows = db.execute(
            "SELECT id, name, data FROM providerConnections WHERE json_extract(data, '$.providerSpecificData.prefix')=?",
            (prefix,)
        ).fetchall()
    else:
        return []
    
    fixed = []
    for conn_id, name, raw in rows:
        data = json.loads(raw)
        old_status = data.get('testStatus', '?')
        
        # Apply healthy defaults
        data['testStatus'] = 'active'
        data['backoffLevel'] = 0
        for key in ['lastError', 'errorCode', 'lastErrorAt']:
            data.pop(key, None)
        for k in list(data.keys()):
            if k.startswith('modelLock_'):
                del data[k]
        
        # For B.AI providers, force /v1 baseUrl
        if 'b.ai' in data.get('providerSpecificData', {}).get('baseUrl', '') and '/v1' not in data.get('providerSpecificData', {}).get('baseUrl', ''):
            data['providerSpecificData']['baseUrl'] = 'https://api.b.ai/v1'
            data['defaultModel'] = 'glm-5.2'
        
        now = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S.000Z')
        db.execute(
            "UPDATE providerConnections SET data=?, isActive=1, updatedAt=? WHERE id=?",
            (json.dumps(data), now, conn_id)
        )
        fixed.append({"id": conn_id[:12], "name": name, "old_status": old_status})
    
    db.commit()
    return fixed


def test_model(model_id):
    """Test a model through 9router"""
    import urllib.request
    payload = json.dumps({
        "model": model_id,
        "messages": [{"role": "user", "content": "PONG"}],
        "max_tokens": 10
    }).encode()
    
    try:
        req = urllib.request.Request(
            f"{ROUTER_HOST}/v1/chat/completions",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode()
            d = json.loads(body.split('\n')[0])
            if d.get('choices'):
                return {"status": "ok", "content": d['choices'][0]['message'].get('content', '')[:30]}
            elif d.get('error'):
                return {"status": "error", "message": d['error']['message'][:80]}
            return {"status": "unknown"}
    except Exception as e:
        return {"status": "error", "message": str(e)[:80]}


# ─── CLI ────────────────────────────────────────────────
def cmd_list(args):
    db = get_db()
    providers = list_providers(db)
    
    print(f"\n{'ID':<12} {'STATUS':<10} {'PREFIX':<8} {'NAME':<20} {'ERROR'}")
    print("─" * 80)
    
    active = sum(1 for p in providers if p['status'] == 'active')
    for p in providers:
        status_icon = "✅" if p['status'] == 'active' else "❌" if p['status'] == 'unavailable' else "⚠️"
        err = p['error'] or ''
        print(f"{p['id']:<12} {status_icon} {p['status']:<8} {p['prefix']:<8} {p['name'][:20]:<20} {str(err)[:25]}")
    
    print(f"\n┌──────────────────────────────────────┐")
    print(f"│ Total: {len(providers):>3} | Active: {active:>3} | Broken: {len(providers)-active:>3} │")
    print(f"└──────────────────────────────────────┘")
    print(f"   DB: {DB}")


def cmd_add(args):
    db = get_db()
    ptype = get_provider_type(args)
    
    if ptype == 'bai':
        result = add_bai_provider(db, args.api_key, args.name)
    else:
        result = add_provider(db, args.name, args.prefix, args.url, args.api_key, args.api_type, args.default_model)
    
    print(f"\n✅ Provider added: {result['name']}")
    print(f"   Connection ID: {result['connection_id']}")
    if result['node_created']:
        print(f"   Node created: {result['node_id']}")
    print(f"   Test: curl {ROUTER_HOST}/v1/chat/completions -d '{{\"model\":\"{args.prefix}/glm-5.2\",\"messages\":[{{\"role\":\"user\",\"content\":\"hi\"}}],\"max_tokens\":10}}'")


def cmd_fix(args):
    db = get_db()
    
    if args.prefix:
        fixed = fix_provider(db, prefix=args.prefix)
        label = f"prefix: {args.prefix}"
    elif args.id:
        fixed = fix_provider(db, conn_id=args.id)
        label = f"id: {args.id}"
    else:
        print("❌ Need --prefix or --id")
        return
    
    if fixed:
        print(f"\n✅ Fixed {len(fixed)} connection(s):")
        for f in fixed:
            print(f"   {f['id']} {f['name']}: {f['old_status']} → active")
    else:
        print(f"❌ No connections found for {label}")


def cmd_fix_all(args):
    db = get_db()
    
    where = "json_extract(data, '$.testStatus') = 'unavailable' OR json_extract(data, '$.errorCode') IS NOT NULL"
    if args.bai:
        where += " AND (json_extract(data, '$.providerSpecificData.baseUrl') LIKE '%b.ai%' OR json_extract(data, '$.providerSpecificData.prefix') = 'bai')"
    
    rows = db.execute(f"SELECT id, name, data FROM providerConnections WHERE {where}").fetchall()
    
    if not rows:
        print("✅ Nothing to fix!")
        return
    
    fixed = []
    for conn_id, name, raw in rows:
        data = json.loads(raw)
        prefix = data.get('providerSpecificData', {}).get('prefix', '')
        
        data['testStatus'] = 'active'
        data['backoffLevel'] = 0
        for key in ['lastError', 'errorCode', 'lastErrorAt']:
            data.pop(key, None)
        for k in list(data.keys()):
            if k.startswith('modelLock_'):
                del data[k]
        
        # B.AI specific fixes
        is_bai = 'b.ai' in data.get('providerSpecificData', {}).get('baseUrl', '') or prefix == 'bai'
        if is_bai:
            data['providerSpecificData']['baseUrl'] = 'https://api.b.ai/v1'
            data['defaultModel'] = 'glm-5.2'
        
        now = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S.000Z')
        db.execute("UPDATE providerConnections SET data=?, isActive=1, updatedAt=? WHERE id=?", (json.dumps(data), now, conn_id))
        fixed.append({"name": name, "prefix": prefix})
    
    db.commit()
    print(f"✅ Fixed {len(fixed)}/{len(rows)} connection(s)")
    for f in fixed:
        print(f"   - {f['prefix']}: {f['name']}")


def cmd_bulk(args):
    if not os.path.exists(args.file):
        print(f"❌ File not found: {args.file}")
        print(f"   Format: one key per line, or name|prefix|url|key per line")
        print(f"   Lines starting with # are ignored")
        return
    
    db = get_db()
    count = 0
    
    with open(args.file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            
            parts = [p.strip() for p in line.split('|')]
            
            if len(parts) >= 4:
                name, prefix, url, key = parts[0], parts[1], parts[2], parts[3]
                api_type = parts[4] if len(parts) >= 5 else 'chat'
                def_model = parts[5] if len(parts) >= 6 else None
                add_provider(db, name, prefix, url, key, api_type, def_model)
                print(f"  ✅ {prefix}: {name}")
            elif len(parts) == 1:
                key = parts[0]
                # Auto-detect type
                if key.startswith('sk-or-v') or 'bai' in args.file.lower():
                    add_bai_provider(db, key)
                    print(f"  ✅ BAI: {key[:20]}...")
                else:
                    print(f"  ⚠️  Skipped (need format: name|prefix|url|key): {key[:20]}...")
            else:
                print(f"  ⚠️  Bad format: {line[:40]}...")
            count += 1
    
    print(f"\n✅ Bulk import complete: {count} provider(s)")


def cmd_test(args):
    result = test_model(args.model)
    if result['status'] == 'ok':
        print(f"✅ {args.model} OK: \"{result['content']}\"")
    else:
        print(f"❌ {args.model}: {result.get('message', '?')}")


# ─── Main ───────────────────────────────────────────────
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="9router Universal Provider Manager v2.1")
    parser.add_argument("--db", help=f"SQLite DB path (default: {DB})")
    sub = parser.add_subparsers(dest="command", required=True)
    
    # list
    p_list = sub.add_parser("list", help="List all providers")
    
    # add
    p_add = sub.add_parser("add", help="Add a provider")
    p_add.add_argument("--name", required=True)
    p_add.add_argument("--prefix", required=True)
    p_add.add_argument("--url", required=True)
    p_add.add_argument("--key", dest="api_key", required=True)
    p_add.add_argument("--api-type", default="chat")
    p_add.add_argument("--default-model")
    p_add.add_argument("--type", choices=PROVIDER_TEMPLATES.keys(), help="Provider type for auto-defaults")
    
    # add-bai
    p_bai = sub.add_parser("add-bai", help="Add B.AI with healthy defaults")
    p_bai.add_argument("--key", dest="api_key", required=True)
    p_bai.add_argument("--name")
    
    # fix
    p_fix = sub.add_parser("fix", help="Fix a broken provider")
    p_fix.add_argument("--prefix")
    p_fix.add_argument("--id")
    
    # fix-all
    p_fa = sub.add_parser("fix-all", help="Fix all broken providers")
    p_fa.add_argument("--bai", action="store_true", help="Fix only B.AI")
    
    # bulk
    p_bulk = sub.add_parser("bulk", help="Bulk import providers from file")
    p_bulk.add_argument("--file", required=True)
    
    # test
    p_test = sub.add_parser("test", help="Test a model")
    p_test.add_argument("--model", required=True)
    
    args = parser.parse_args()
    
    # Override DB from env/arg
    if args.db:
        DB = args.db
    
    {
        "list": cmd_list,
        "add": cmd_add,
        "add-bai": cmd_add,
        "fix": cmd_fix,
        "fix-all": cmd_fix_all,
        "bulk": cmd_bulk,
        "test": cmd_test,
    }[args.command](args)
