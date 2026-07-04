# 9router — Add Custom Provider (No Rebuild)

Cara nambah provider **OpenAI-compatible** (iamhc, OpenRouter, Groq, dll) ke [9router](https://github.com/) **tanpa perlu rebuild** — cukup insert langsung ke database SQLite, restart, selesai.

> Kenapa lewat database? Kalau edit `registry/index.js` kamu wajib `npm run build` ulang (lama + gampang error). Insert ke DB langsung ke-detect setelah restart.

---

## 🤖 Prompt Buat AI Agent

Copy-paste ini ke AI agent kamu (ganti `[API_KEY]` sama key kamu):

```
Tolong tambahkan provider iamhc ke 9router saya.

Lokasi:
- 9router: ~/9router/
- Database: ~/.9router/db/data.sqlite
- Port: 20128

Langkah:
1. Insert node iamhc ke database:
   sqlite3 ~/.9router/db/data.sqlite "INSERT OR REPLACE INTO providerNodes (id, type, name, config, createdAt, updatedAt) VALUES ('openai-compatible-chat-iamhc', 'openai-compatible-chat', 'iamhc', '{\"prefix\":\"iamhc\",\"apiType\":\"chat\",\"baseUrl\":\"https://api.iamhc.cn/v1\",\"nodeName\":\"iamhc\"}', datetime('now'), datetime('now'));"

2. Restart 9router di background:
   pkill -f "next.*9router"; fuser -k 20128/tcp; sleep 3
   cd ~/9router && PORT=20128 nohup npm start > /tmp/9router.log 2>&1 &
   sleep 10 && curl http://localhost:20128/api/health

3. Kasih tau saya buat add API key via dashboard:
   http://localhost:20128/dashboard/providers/new

API key iamhc saya: [API_KEY]
```

---

## 🔧 Manual (Step by Step)

### Step 1 — Insert Node ke Database

```bash
sqlite3 ~/.9router/db/data.sqlite "
INSERT OR REPLACE INTO providerNodes (id, type, name, config, createdAt, updatedAt)
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

### Step 2 — Restart 9router (background)

```bash
pkill -f "next.*9router" 2>/dev/null
fuser -k 20128/tcp 2>/dev/null
sleep 3

cd ~/9router && PORT=20128 nohup npm start > /tmp/9router.log 2>&1 &

sleep 10
curl -s http://localhost:20128/api/health   # → {"ok":true}
```

### Step 3 — Add API Key via Dashboard

1. Buka `http://<IP>:20128/dashboard/providers/new`
2. Pilih provider yang barusan di-insert (misal **iamhc**)
3. Masukin API key → Save → Test

### Step 4 — Verify

```bash
curl -s http://localhost:20128/api/providers | python3 -c "
import json,sys
d=json.load(sys.stdin)
for c in d.get('connections',[]):
    print(c.get('name','?'), '->', c.get('testStatus','?'))
"
```

---

## 📦 Provider Lain (tinggal ganti)

| Provider | Base URL |
|----------|----------|
| **iamhc** | `https://api.iamhc.cn/v1` |
| OpenRouter | `https://openrouter.ai/api/v1` |
| Together.ai | `https://api.together.xyz/v1` |
| Groq | `https://api.groq.com/openai/v1` |
| Fireworks | `https://api.fireworks.ai/inference/v1` |
| SiliconFlow | `https://api.siliconflow.cn/v1` |

Format insert-nya sama, tinggal ganti `id`, `name`, `prefix`, dan `baseUrl`.

### Bulk Insert (banyak provider sekaligus)

```bash
sqlite3 ~/.9router/db/data.sqlite "
INSERT OR REPLACE INTO providerNodes (id, type, name, config, createdAt, updatedAt) VALUES
  ('openai-compatible-chat-iamhc', 'openai-compatible-chat', 'iamhc', '{\"prefix\":\"iamhc\",\"apiType\":\"chat\",\"baseUrl\":\"https://api.iamhc.cn/v1\",\"nodeName\":\"iamhc\"}', datetime('now'), datetime('now')),
  ('openai-compatible-chat-openrouter', 'openai-compatible-chat', 'openrouter', '{\"prefix\":\"or\",\"apiType\":\"chat\",\"baseUrl\":\"https://openrouter.ai/api/v1\",\"nodeName\":\"openrouter\"}', datetime('now'), datetime('now')),
  ('openai-compatible-chat-groq', 'openai-compatible-chat', 'groq', '{\"prefix\":\"groq\",\"apiType\":\"chat\",\"baseUrl\":\"https://api.groq.com/openai/v1\",\"nodeName\":\"groq\"}', datetime('now'), datetime('now'))
;
"
```

---

## 🛠️ Utility

```bash
# List semua custom node
sqlite3 ~/.9router/db/data.sqlite "SELECT id, name, json_extract(config,'$.baseUrl') FROM providerNodes"

# Hapus satu node
sqlite3 ~/.9router/db/data.sqlite "DELETE FROM providerNodes WHERE name='iamhc'"
```

---

## ⚠️ Pitfalls

1. **Jangan edit `registry/index.js`** — itu auto-generated, butuh rebuild. Pakai DB.
2. **Port conflict** — pastikan `20128` free sebelum start (`fuser -k 20128/tcp`).
3. **API key ke-mask** — key yang udah masuk di-mask di response, gak bisa di-retrieve balik via API.
4. **Cek health** — selalu verify `{"ok":true}` sebelum add key.
