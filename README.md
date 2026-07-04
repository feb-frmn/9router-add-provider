# 9router — Provider Setup Guide

Everything you need to wire up AI providers in [9router](https://github.com/): the **94 providers that ship built-in**, plus how to bolt on **any OpenAI-compatible endpoint that isn't in the registry** (like `iamhc`) — using the same API the dashboard uses.

Two paths:

| You want to add… | How | Restart? |
|---|---|---|
| A provider already in the registry (OpenAI, Groq, Together, DeepSeek, +90 more) | Dashboard → New → pick it → paste key | No |
| An OpenAI-compatible endpoint **not** in the registry (e.g. `iamhc`) | 2 API calls: create node → attach key | No |

> Heads up: don't try to hand-insert rows with the `sqlite3` CLI. 9router loads its DB into memory (sql.js) at startup, so raw CLI writes are invisible to the running process. Use the HTTP API below — it's what the dashboard calls, and it works live with no restart.

---

## Path 1 — Built-in providers (the common case)

9router ships with **94 providers** out of the box. No API calls, no restart:

1. Open `http://<host>:20128/dashboard/providers/new`
2. Pick the provider
3. Paste your API key (or run the OAuth flow)
4. Save → hit **Test**

Full catalog at the bottom — check it before reaching for Path 2.

---

## Path 2 — Custom OpenAI-compatible endpoint (e.g. iamhc)

For any provider that isn't built-in but exposes a standard `/v1/chat/completions` (OpenAI-compatible) API. Two calls, done.

### Step 1 — Create the node

```bash
curl -s -X POST http://localhost:20128/api/provider-nodes \
  -H "Content-Type: application/json" \
  -d '{
    "name": "iamhc",
    "prefix": "iamhc",
    "apiType": "chat",
    "baseUrl": "https://api.iamhc.cn/v1",
    "type": "openai-compatible"
  }'
```

Response contains the node id — grab it:

```json
{"node":{"id":"openai-compatible-chat-9b70da90-...","type":"openai-compatible","name":"iamhc","prefix":"iamhc","apiType":"chat","baseUrl":"https://api.iamhc.cn/v1"}}
```

- `prefix` is how you'll call models later: `iamhc/<model>`.
- `apiType` is `chat` (standard) or `responses` (OpenAI Responses API).
- `baseUrl` is the root — **no** `/chat/completions` suffix; 9router appends it.

### Step 2 — Attach your API key

Use the **full node id** from step 1 as the `provider` field (this is the bit people get wrong — it's the long id, not the short name):

```bash
NODE_ID="openai-compatible-chat-9b70da90-..."   # from step 1

curl -s -X POST http://localhost:20128/api/providers \
  -H "Content-Type: application/json" \
  -d "{
    \"provider\": \"${NODE_ID}\",
    \"name\": \"iamhc\",
    \"apiKey\": \"sk-YOUR-KEY\"
  }"
```

That's it — the provider is live immediately, no restart.

### Step 3 — Verify with a real completion

Model format is `<prefix>/<model>`:

```bash
curl -s -X POST http://localhost:20128/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "iamhc/Kimi-K2.6",
    "messages": [{"role":"user","content":"reply with exactly: PONG"}],
    "max_tokens": 20
  }'
```

A real model response back = you're done.

### One-liner (both steps, auto-parses the id)

```bash
API_KEY="sk-YOUR-KEY"
NODE_ID=$(curl -s -X POST http://localhost:20128/api/provider-nodes \
  -H "Content-Type: application/json" \
  -d '{"name":"iamhc","prefix":"iamhc","apiType":"chat","baseUrl":"https://api.iamhc.cn/v1","type":"openai-compatible"}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['node']['id'])")

curl -s -X POST http://localhost:20128/api/providers \
  -H "Content-Type: application/json" \
  -d "{\"provider\":\"${NODE_ID}\",\"name\":\"iamhc\",\"apiKey\":\"${API_KEY}\"}"
```

### Managing nodes

```bash
# List all custom nodes
curl -s http://localhost:20128/api/provider-nodes | python3 -m json.tool

# Delete a node by id
curl -s -X DELETE http://localhost:20128/api/provider-nodes/<NODE_ID>
```

### Anthropic-compatible or embeddings?

Same `/api/provider-nodes` call, just change `type`:

- `"type": "anthropic-compatible"` for Claude-style `/v1/messages` endpoints (drop `apiType`)
- `"type": "custom-embedding"` for embedding endpoints (drop `apiType`)

---

## Robot prompt (hand this to your AI agent)

Copy-paste, swap `[API_KEY]`, done:

```
Add a custom OpenAI-compatible provider "iamhc" to my running 9router (port 20128).

Do NOT use the sqlite3 CLI — 9router runs its DB in memory (sql.js), so raw SQL inserts
are invisible to the live process. Use 9router's HTTP API instead (same as the dashboard):

Step 1 — create the node, capture its id:
  curl -s -X POST http://localhost:20128/api/provider-nodes \
    -H "Content-Type: application/json" \
    -d '{"name":"iamhc","prefix":"iamhc","apiType":"chat","baseUrl":"https://api.iamhc.cn/v1","type":"openai-compatible"}'

Step 2 — attach the API key, using the FULL node id from step 1 as "provider":
  curl -s -X POST http://localhost:20128/api/providers \
    -H "Content-Type: application/json" \
    -d '{"provider":"<NODE_ID_FROM_STEP_1>","name":"iamhc","apiKey":"[API_KEY]"}'

Step 3 — verify with a real completion (model = <prefix>/<model>):
  curl -s -X POST http://localhost:20128/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"iamhc/Kimi-K2.6","messages":[{"role":"user","content":"say PONG"}],"max_tokens":20}'

If step 3 returns a model reply, it's working. No restart needed.
```

---

## Gotchas (all learned the hard way)

- **Don't use the `sqlite3` CLI.** The live process uses sql.js in-memory; CLI writes aren't seen and can be clobbered. Use the HTTP API.
- **`provider` = the full node id.** In step 2, `provider` must be the long `openai-compatible-chat-<uuid>` id from step 1, not the short name. Passing `"iamhc"` gives `Invalid provider`.
- **`baseUrl` has no `/chat/completions` suffix.** Give the root (e.g. `https://api.iamhc.cn/v1`); 9router appends the path.
- **One connection per node.** Each node accepts a single API key. Need a second key? Create a second node.
- **Keys are masked on read.** Once saved, the API won't return the key in plaintext — keep your own copy.
- **Health check first.** `curl -s http://localhost:20128/api/health` should return `{"ok":true}`.
- **Port stuck** (`EADDRINUSE :::20128`)? An old process holds it — `fuser -k 20128/tcp`, then restart.

---

## Built-in provider catalog (all 94)

Already in 9router — just pick them in the dashboard (Path 1). Grouped by type.

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

*Verified against a live 9router instance on 2026-07-04: node creation → key attach → real `iamhc/Kimi-K2.6` completion all confirmed working via the HTTP API. If your provider isn't in the catalog above, use Path 2.*
