# Manual Guide — Adding Custom Providers to 9router

Two methods: HTTP API (recommended) or direct DB injection.

## Method 1 — HTTP API (recommended)

This is what the dashboard uses internally. Works live, no restart.

### Step 1 — Create provider node

```bash
curl -s -X POST http://localhost:20128/api/provider-nodes \
  -H "Content-Type: application/json" \
  -d '{
    "name": "inference",
    "prefix": "inf",
    "apiType": "chat",
    "baseUrl": "https://api.inference.net/v1",
    "type": "openai-compatible"
  }'
```

Response:
```json
{
  "node": {
    "id": "openai-compatible-chat-c34984a4-...",
    "type": "openai-compatible",
    "name": "inference",
    "prefix": "inf"
  }
}
```

**Save the `id`** — you need it for step 2.

### Step 2 — Attach your API key

Use the **full node id** (the long one from step 1):

```bash
curl -s -X POST http://localhost:20128/api/providers \
  -H "Content-Type: application/json" \
  -d '{
    "provider": "openai-compatible-chat-c34984a4-...",
    "name": "inference",
    "apiKey": "sk-your-key"
  }'
```

### Step 3 — Test

```bash
curl -s http://localhost:20128/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "inf/glm-5.2",
    "messages": [{"role":"user","content":"say PONG"}],
    "max_tokens": 10
  }'
```

If you get a model response → done.

---

## Method 2 — Direct DB injection

Use when HTTP API is down or flaky. 9router uses **better-sqlite3** with WAL mode — the DB is a real file, not in-memory. External writes through WAL are visible to the live process.

DB location: `/var/lib/9router/db/data.sqlite`

### Tables

```
providerNodes        — provider definitions (prefix, baseUrl, type)
providerConnections  — API keys + connection state (status, errors, model locks)
```

### Insert a provider

```python
import json, sqlite3, uuid, datetime

db = sqlite3.connect('/var/lib/9router/db/data.sqlite')
now = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S.000Z')

# 1. Create node
node_id = f"openai-compatible-chat-{uuid.uuid4()}"
node_data = json.dumps({
    "prefix": "inf",
    "apiType": "chat",
    "baseUrl": "https://api.inference.net/v1",
    "nodeName": "inference"
})

db.execute(
    "INSERT INTO providerNodes (id, type, name, data, createdAt, updatedAt) VALUES (?,?,?,?,?,?)",
    (node_id, "openai-compatible", "inference", node_data, now, now)
)

# 2. Create connection
conn_id = str(uuid.uuid4())
conn_data = json.dumps({
    "apiKey": "sk-your-key",
    "testStatus": "active",
    "providerSpecificData": {
        "prefix": "inf",
        "apiType": "chat",
        "baseUrl": "https://api.inference.net/v1",
        "nodeName": "inference",
        "connectionProxyEnabled": False,
        "connectionProxyUrl": "",
        "connectionNoProxy": ""
    },
    "backoffLevel": 0
})

db.execute(
    "INSERT INTO providerConnections (id, provider, authType, name, priority, isActive, data, createdAt, updatedAt) VALUES (?,?,?,?,?,?,?,?,?)",
    (conn_id, node_id, "apikey", "inference", 1, 1, conn_data, now, now)
)

db.commit()
db.close()
print("Done!")
```

### Fix a broken provider

```python
import json, sqlite3

db = sqlite3.connect('/var/lib/9router/db/data.sqlite')
row = db.execute(
    "SELECT data FROM providerConnections WHERE json_extract(data, '$.providerSpecificData.prefix')='inf'"
).fetchone()

data = json.loads(row[0])

# Clear errors
data['testStatus'] = 'active'
data.pop('lastError', None)
data.pop('errorCode', None)
data.pop('lastErrorAt', None)
data['backoffLevel'] = 0

# Clear model locks
for key in [k for k in data if k.startswith('modelLock_')]:
    del data[key]

# Optional: fix baseUrl
data['providerSpecificData']['baseUrl'] = 'https://api.inference.net/v1'

db.execute(
    "UPDATE providerConnections SET data=?, isActive=1 WHERE json_extract(data, '$.providerSpecificData.prefix')='inf'",
    (json.dumps(data),)
)
db.commit()
db.close()
```

---

## Discover available models

Most OpenAI-compatible providers expose a `/models` endpoint:

```bash
curl -s https://api.inference.net/v1/models \
  -H "Authorization: Bearer sk-your-key" | python3 -m json.tool
```

⚠️ **Model names vary wildly between providers.** Some use short names (`glm-5.2`), others use full paths (`deepseek/deepseek-v3/fp-8`). Always check `/models` first!

In 9router, you call them as `<prefix>/<model>`:
- `inf/deepseek/deepseek-v3/fp-8` (inference.net)
- `iamhc/Kimi-K2.6` (iamhc)
- `bg/glm-5.2` (bigmodel)

---

## Gotchas

1. **`baseUrl` = root only.** Give `https://api.inference.net/v1`, NOT `https://api.inference.net/v1/chat/completions`. 9router appends the path.

2. **`provider` field in step 2 = the FULL node id.** It's the long `openai-compatible-chat-<uuid>` string, not the short name. Passing `"inference"` gives `Invalid provider`.

3. **One key per connection.** Need multiple keys for the same provider? Create multiple connections pointing to the same node.

4. **Keys are masked on read.** The API never returns your key in plaintext after saving.

5. **Model names are provider-specific.** Don't assume short names work — check `/models` endpoint or provider docs. Inference.net uses `org/model/quant` format, iamhc uses `Model-Name`, bigmodel uses `glm-X.Y`.

6. **Provider types:**
   - `openai-compatible` — standard `/v1/chat/completions` (most providers)
   - `anthropic-compatible` — Claude-style `/v1/messages`
   - `custom-embedding` — embedding endpoints

7. **API types:**
   - `chat` — standard chat completions (default)
   - `responses` — OpenAI Responses API format

8. **DB is file-based** (better-sqlite3 with WAL mode). Both HTTP API and direct `sqlite3` CLI work. Changes are visible to the live process immediately.
