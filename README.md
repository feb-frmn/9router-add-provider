# 9router — Provider Setup Guide

Everything you need to wire up AI providers in [9router](https://github.com/): the **94 providers that ship built-in**, plus how to bolt on **any OpenAI-compatible endpoint that isn't in the registry** (like `iamhc`) without rebuilding.

Two paths, and it's important not to mix them up:

| You want to add… | Path | Rebuild? |
|---|---|---|
| A provider already in the registry (OpenAI, Groq, Together, DeepSeek, 90 others) | Dashboard → New → pick it → paste key | No |
| An OpenAI-compatible endpoint **not** in the registry (e.g. `iamhc`) | Insert a node into the SQLite DB → restart → paste key | No (just a restart) |

> TL;DR — you almost never need to touch code. If the provider ships with 9router, the dashboard has it. The DB trick is only for custom endpoints the registry doesn't know about yet.

---

## Path 1 — Built-in providers (the common case)

9router ships with **94 providers** out of the box. No DB edits, no rebuild. Just:

1. Open `http://<host>:20128/dashboard/providers/new`
2. Pick the provider
3. Paste your API key (or run the OAuth flow)
4. Save → hit **Test**

That's it. The full list is at the bottom of this README so you can confirm yours is already there before reaching for Path 2.

---

## Path 2 — Custom OpenAI-compatible endpoint (e.g. iamhc)

Use this **only** when your provider isn't in the built-in list but exposes a standard `/v1/chat/completions` (OpenAI-compatible) API.

### Why the DB instead of editing code

You *could* add a file under `open-sse/providers/registry/` and regenerate `index.js` — but that's an auto-generated import list, and any change means `npm run build` (slow, easy to break). Inserting a node straight into SQLite skips all of that. The provider shows up in the dashboard after a restart.

### Heads up on the schema

The `providerNodes` table columns are:

```
id TEXT PRIMARY KEY, type TEXT, name TEXT, data TEXT NOT NULL, createdAt TEXT, updatedAt TEXT
```

The config JSON goes in the **`data`** column. (If you see `Error: no such column: config`, you used the wrong column name — it's `data`.)

### Step 1 — Insert the node

```bash
sqlite3 ~/.9router/db/data.sqlite "
INSERT OR REPLACE INTO providerNodes (id, type, name, data, createdAt, updatedAt)
VALUES (
  'openai-compatible-chat-iamhc',
  'openai-compatible-chat',
  'iamhc',
  '{\"prefix\":\"iamhc\",\"apiType\":\"chat\",\"baseUrl\":\"https://api.iamhc.cn/v1\",\"nodeName\":\"iamhc\"}',
  datetime('now'),
  datetime('now')
);
"
```

Swap the four values (`id` suffix, `name`, `prefix`, `baseUrl`) for any other custom endpoint.

### Step 2 — Restart (a fresh node won't appear until you do)

```bash
pkill -f "next.*9router" 2>/dev/null
fuser -k 20128/tcp 2>/dev/null   # free the port if it's stuck
sleep 3

cd ~/9router && PORT=20128 nohup npm start > /tmp/9router.log 2>&1 &

sleep 10
curl -s http://localhost:20128/api/health   # expect {"ok":true}
```

### Step 3 — Add your key in the dashboard

`http://<host>:20128/dashboard/providers/new` → pick your provider (e.g. **iamhc**) → paste key → Save → Test.

### Step 4 — Verify it's live

```bash
curl -s http://localhost:20128/api/providers | python3 -c "
import json, sys
for c in json.load(sys.stdin).get('connections', []):
    print(c.get('name','?'), '->', c.get('testStatus','?'))
"
```

### Managing custom nodes

```bash
# List everything you've added
sqlite3 ~/.9router/db/data.sqlite \
  "SELECT name, json_extract(data,'\$.baseUrl') FROM providerNodes"

# Remove one
sqlite3 ~/.9router/db/data.sqlite "DELETE FROM providerNodes WHERE name='iamhc'"
```

---

## Robot prompt (hand this to your AI agent)

Copy-paste, swap `[API_KEY]`, done:

```
Add a custom OpenAI-compatible provider called "iamhc" to my 9router.

Environment:
- 9router lives at ~/9router/
- SQLite DB at ~/.9router/db/data.sqlite
- Runs on port 20128

Do this:
1. Insert the node (note: the config JSON goes in the `data` column, not `config`):
   sqlite3 ~/.9router/db/data.sqlite "INSERT OR REPLACE INTO providerNodes (id, type, name, data, createdAt, updatedAt) VALUES ('openai-compatible-chat-iamhc', 'openai-compatible-chat', 'iamhc', '{\"prefix\":\"iamhc\",\"apiType\":\"chat\",\"baseUrl\":\"https://api.iamhc.cn/v1\",\"nodeName\":\"iamhc\"}', datetime('now'), datetime('now'));"

2. Restart 9router in the background:
   pkill -f "next.*9router"; fuser -k 20128/tcp; sleep 3
   cd ~/9router && PORT=20128 nohup npm start > /tmp/9router.log 2>&1 &
   sleep 10 && curl -s http://localhost:20128/api/health   # want {"ok":true}

3. Tell me to add the API key in the dashboard at:
   http://localhost:20128/dashboard/providers/new

My iamhc API key: [API_KEY]
```

---

## Gotchas

- **`data` vs `config`** — the config column is `data`. Wrong name → `no such column: config`.
- **Restart is mandatory** for a new DB node to show up. A running instance won't hot-reload it.
- **Port already in use** (`EADDRINUSE :::20128`) — an old process is still holding it. `fuser -k 20128/tcp` then start again.
- **Keys are masked on read** — once saved, the API won't hand a key back to you in plaintext. Keep your own copy.
- **OpenAI-compatible only** — Path 2 assumes a standard `/v1/chat/completions` shape. Providers with bespoke formats (Claude messages, Gemini, protobuf, etc.) already have dedicated built-in entries; use those.
- **Always health-check** `{"ok":true}` before adding keys.

---

## Built-in provider catalog (all 94)

Everything below is already in 9router — just pick it in the dashboard. Grouped by type.

### LLM APIs — API key (31)

`alicode` · `alicode-intl` · `anthropic` · `azure` · `blackbox` · `cerebras` · `chutes` · `cohere` · `commandcode` · `deepseek` · `fireworks` · `glm` · `glm-cn` · `groq` · `huggingface` · `hyperbolic` · `kimi` · `minimax` · `minimax-cn` · `mistral` · `mmf` · `nebius` · `openai` · `opencode-go` · `perplexity` · `siliconflow` · `together` · `vertex-partner` · `volcengine-ark` · `xiaomi-mimo` · `xiaomi-tokenplan`

### LLM — OAuth login (13)

`antigravity` · `claude` · `cline` · `codebuddy-cn` · `codex` · `cursor` · `github` (Copilot) · `gitlab` · `iflow` · `kilocode` · `kimi-coding` · `qwen` · `xai`

### LLM — free / free-tier (13)

`byteplus` · `cloudflare-ai` · `gemini` · `gemini-cli` · `kiro` · `local-device` · `mimo-free` · `nvidia` · `ollama` · `opencode` · `openrouter` · `qoder` · `vertex`

### LLM — web/cookie session (2)

`grok-web` · `perplexity-web`

### Image / audio / video / media (22)

`assemblyai` · `aws-polly` · `black-forest-labs` · `cartesia` · `comfyui` · `coqui` · `deepgram` · `edge-tts` · `elevenlabs` · `fal-ai` · `google-tts` · `inworld` · `nanobanana` · `ollama-local` · `playht` · `recraft` · `runwayml` · `sdwebui` · `stability-ai` · `topaz` · `tortoise` · `vercel-ai-gateway`

### Search / web tools (12)

`brave-search` · `exa` · `firecrawl` · `google-pse` · `jina-ai` · `jina-reader` · `linkup` · `searchapi` · `searxng` · `serper` · `tavily` · `youcom`

### Embeddings (1)

`voyage-ai`

---

*Catalog verified against the 9router registry on 2026-07-04. If yours isn't listed here, use Path 2.*
