# 9router — Add Any Provider

Scripts + guide for adding **any** AI provider to [9router](https://github.com/) — built-in or custom.

## Quick Start

```bash
# Add a custom OpenAI-compatible provider (e.g. inference.net)
bash add-provider.sh \
  --name "inference" \
  --prefix "inf" \
  --url "https://api.inference.net/v1" \
  --key "sk-your-key"

# That's it. Use it: inf/glm-5.2, inf/claude-opus-4.6, etc.
```

## What's in the repo

| File | What it does |
|---|---|
| `add-provider.sh` | One command to add any custom provider (create node + attach key + verify) |
| `add-provider-db.sh` | Same thing but injects directly into the SQLite DB (for when HTTP API is flaky) |
| `list-providers.sh` | Show all providers, connections, and their status |
| `fix-provider.sh` | Fix a broken/red provider (clear errors, model locks, reset backoff) |
| `providers.md` | Full catalog of all 94 built-in providers |
| `examples/` | Ready-to-use configs for popular unknown providers |

## Two ways to add providers

### Path 1 — Built-in (94 providers)

Already in 9router. Just open the dashboard:

```
http://<host>:20128/dashboard/providers/new
```

Pick the provider → paste API key → done. See [providers.md](providers.md) for the full list.

### Path 2 — Custom / Unknown provider

Any OpenAI-compatible endpoint not in the registry. Use the script:

```bash
bash add-provider.sh \
  --name "inference"                        \
  --prefix "inf"                            \
  --url "https://api.inference.net/v1"      \
  --key "sk-your-key"                       \
  --host "localhost:20128"                   # optional, default localhost:20128
```

Or do it manually — see [manual-guide.md](manual-guide.md).

## Fix a broken provider

Provider showing red in dashboard? Clear its error state:

```bash
bash fix-provider.sh --prefix "inf"
# or by connection ID:
bash fix-provider.sh --id "7fbad63f-002a-4c99-8c5a-0461482abaa8"
```

## Examples

Ready configs in `examples/` — just swap the API key:

```bash
# Inference.net (GLM-5.2, Claude Opus 4.6, Nemotron 3 Super)
bash add-provider.sh --config examples/inference-net.env

# iamhc.cn (Kimi-K2.6, DeepSeek-V4-Pro, GLM models)
bash add-provider.sh --config examples/iamhc.env

# LLM7 (GPT-OSS-120B, GLM-4.6V-Flash)
bash add-provider.sh --config examples/llm7.env
```

## Important notes

- **`baseUrl` = root only.** No `/chat/completions` suffix — 9router appends it.
- **One key per node.** Need multiple keys? Create multiple nodes (same prefix is fine).
- **Model format:** `<prefix>/<model>` — e.g. `inf/glm-5.2`, `iamhc/Kimi-K2.6`
- **No restart needed.** Everything is live immediately.
- **DB is file-based** (better-sqlite3 with WAL mode). Both HTTP API and direct DB injection work.

## License

MIT — do whatever you want with it.
