# 9router — Add Any Provider

Scripts + Python CLI + Telegram Bot for adding **any** AI provider to [9router](https://github.com/decolua/9router).

> ⚠️ **Tested on 9router v0.5.20 only.**  
> DB path changed in v0.5.20 to file-based better-sqlite3 (`/var/lib/9router/db/data.sqlite`).  
> Older versions use in-memory sql.js — direct DB injection won't work on those.

## Quick Start

```bash
# Python CLI (recommended — supports all providers)
python3 provider-manager.py add --type bai --key "sk-or-v1-xxx"

# Or bash (legacy — one provider at a time)
 --key "sk-or-v1-xxx"
```

---

## What's in the repo

| File | What it does |
|------|-------------|
| `provider-manager.py` | **Unified Python CLI** — add, list, fix, bulk, test any provider |
| `bot.py` | **Telegram bot** — manage providers from your phone |
| `add-provider.sh` | Bash — add any custom provider (HTTP API method) |
| `add-provider-db.sh` | Bash — same but direct DB injection |
| `add.sh` | Bash — add/fix B.AI (chat.b.ai) with healthy defaults |
| `fix-provider.sh` | Bash — fix a single broken/red provider |
| `fix-all.sh` | Bash — fix ALL broken providers at once |
| `list-providers.sh` | Bash — list all providers and their status |
| `providers.md` | Full catalog of all 94 built-in providers |
| `examples/` | Ready-to-use config templates |
| `requirements.txt` | Python deps (bot only — CLI needs no deps) |

---

## Python CLI (`provider-manager.py`)

No dependencies needed — uses stdlib only.

```bash
# Make executable or run with python3
python3 provider-manager.py list

python3 provider-manager.py add --type bai --key "sk-or-v1-xxx"

python3 provider-manager.py add \
  --name "my-iamhc" \
  --prefix "iamhc" \
  --url "https://api.iamhc.cn/v1" \
  --key "sk-xxx"

python3 provider-manager.py fix --prefix "bai"
python3 provider-manager.py fix-all
python3 provider-manager.py fix-all --bai

# Bulk import from file
# Format: name|prefix|url|key|api_type|default_model
python3 provider-manager.py bulk --file keys.txt

# Test a model
python3 provider-manager.py test --model "bai/glm-5.2"
```

### Supported provider types

| Type | Prefix | Default URL | Notes |
|------|--------|-------------|-------|
| `bai` | `bai` | `https://api.b.ai/v1` | B.AI — healthy defaults (glm-5.2, no deposit check) |
| `iamhc` | `iamhc` | `https://api.iamhc.cn/v1` | iamhc.cn |
| `inf` | `inf` | `https://api.inference.net/v1` | Inference.net |
| `openai` | `openai` | `https://api.openai.com/v1` | Official OpenAI |
| `custom` | `custom` | (required) | Any OpenAI-compatible endpoint |

---

## Telegram Bot (`bot.py`)

Manage your 9router from anywhere via Telegram.

### Setup

```bash
# 1. Install deps
pip install python-telegram-bot

# 2. Get bot token from @BotFather

# 3. Set environment variables
export TELEGRAM_BOT_TOKEN="your-bot-token"
export TELEGRAM_OWNER_ID="your-telegram-id"

# 4. Run
python3 bot.py
```

### Commands

| Command | What it does |
|---------|-------------|
| `/list` | Full provider list with status |
| `/status` | Quick summary (active/total per prefix) |
| `/addbai sk-or-v1-xxx` | Add B.AI key instantly |
| `/add iamhc sk-xxx` | Add any provider by type |
| `/add openai sk-xxx` | Add OpenAI key |
| `/fix` | Fix all broken providers |
| `/fixbai` | Fix only B.AI providers |
| `/test bai/glm-5.2` | Test a model through 9router |

---

## B.AI (chat.b.ai) — Special Handling

B.AI keys get **403 "Deposit required"** on premium models (gpt-\*, kimi-\*) but **GLM-5.2 works free** (~1M tokens/day).

**The problem:** 9router tests connections with premium models → gets 403 → marks the whole connection as `unavailable` (red).

**The fix:** These scripts inject keys with **healthy defaults**:
- `baseUrl: https://api.b.ai/v1` (correct endpoint)
- `defaultModel: glm-5.2` (skips deposit check)
- `testStatus: active` (green from start)
- `backoffLevel: 0`
- No `lastError`, no `modelLock_*`

```bash
# Add a B.AI key (CLI)
python3 provider-manager.py add --type bai --key "sk-or-v1-xxx"

# Fix existing B.AI connections
python3 provider-manager.py fix --prefix "bai"

# Test
curl -s http://localhost:20128/v1/chat/completions \
  -d '{"model":"bai/glm-5.2","messages":[{"role":"user","content":"PONG"}],"max_tokens":10}'
```

---

## Bash Scripts (Legacy)

```bash
# Add custom provider via HTTP API
bash add-provider.sh \
  --name "inference" \
  --prefix "inf" \
  --url "https://api.inference.net/v1" \
  --key "sk-your-key"

# Same but direct DB injection (works when dashboard is down)
bash add-provider-db.sh \
  --name "inference" \
  --prefix "inf" \
  --url "https://api.inference.net/v1" \
  --key "sk-your-key"

# Fix a broken provider by prefix
bash fix-provider.sh --prefix "inf"

# Fix ALL broken providers
bash fix-all.sh

# List all providers
bash list-providers.sh
```

---

## Bulk Import

**Format (pipe-separated, one per line):**
```
name|prefix|baseUrl|apiKey|apiType|defaultModel
my-iamhc|iamhc|https://api.iamhc.cn/v1|sk-xxx|chat|
my-bai|bai|https://api.b.ai/v1|sk-or-v1-xxx|chat|glm-5.2
```

**Using Python CLI:**
```bash
python3 provider-manager.py bulk --file keys.txt
```

**Using Telegram bot:**  
Send the file to the bot (one key per line, or pipe-separated format).

---

## Fix Broken Providers

Python CLI:
```bash
# Fix all red providers
python3 provider-manager.py fix-all

# Fix only B.AI
python3 provider-manager.py fix-all --bai

# Fix by prefix
python3 provider-manager.py fix --prefix "bai"
```

Bash:
```bash
bash fix-all.sh
bash fix-all.sh --bai
bash fix-provider.sh --prefix "inf"
```

---

## Important Notes

- **`baseUrl` = root only.** No `/chat/completions` suffix — 9router appends it.
- **One key per connection.** Multiple connections on same node = load balancing.
- **Model format:** `<prefix>/<model>` — e.g. `bai/glm-5.2`, `iamhc/Kimi-K2.6`
- **No restart needed.** DB changes are live immediately (better-sqlite3 WAL mode).
- **v0.5.20 only.** DB path: `/var/lib/9router/db/data.sqlite`. Set `ROUTER_DB` env to override.
- **B.AI caution:** Don't use premium models (gpt-5\*, kimi-kl\*) — they require deposit and will 403. Stick to GLM models.

## License

MIT — do whatever you want with it.
