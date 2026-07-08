#!/usr/bin/env python3
"""
9router Manager Telegram Bot
Control your 9router providers from Telegram.

Setup:
  1. Save as bot.py next to provider-manager.py
  2. Set env vars:
     export TELEGRAM_BOT_TOKEN="your-bot-token"
     export TELEGRAM_OWNER_ID="your-telegram-id"
  3. python3 bot.py
  4. Or use: nohup python3 bot.py &

Commands:
  /start     - Welcome
  /list      - List all providers and status
  /add <type> <key> - Add provider (type: bai, iamhc, inf, openai, custom)
  /addbai <key> - Quick add B.AI key with healthy defaults
  /fix       - Fix all broken providers
  /fixbai    - Fix B.AI providers only
  /test <model> - Test a model
  /status    - Quick summary of all providers
"""

import os, sys, json, sqlite3, uuid, datetime, secrets, logging, asyncio
from pathlib import Path

# Add parent dir to path for provider-manager import
sys.path.insert(0, str(Path(__file__).parent))
from provider_manager import (
    DB, ROUTER_HOST, get_db, list_providers, fix_provider, test_model,
    add_bai_provider, add_provider, PROVIDER_TEMPLATES
)

BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
OWNER_ID = int(os.environ.get("TELEGRAM_OWNER_ID", "0"))

if not BOT_TOKEN:
    print("❌ Set TELEGRAM_BOT_TOKEN env var")
    print("   Get token from @BotFather on Telegram")
    sys.exit(1)

if not OWNER_ID:
    print("⚠️  Set TELEGRAM_OWNER_ID env var to restrict access")
    print("   Your ID: run /start once, check logs for sender_id")

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger(__name__)


def format_providers_table(providers):
    """Format provider list as Telegram-friendly table"""
    if not providers:
        return "No providers found."
    
    active = sum(1 for p in providers if p['status'] == 'active')
    lines = [f"📊 *9router Providers* — {active}/{len(providers)} active\n"]
    
    for p in providers:
        icon = "🟢" if p['status'] == 'active' else "🔴" if p['status'] == 'unavailable' else "🟡"
        err = f" ({p['error']})" if p['error'] else ""
        lines.append(f"{icon} `{p['prefix']}` {p['name'][:20]} — {p['status']}{err}")
    
    return "\n".join(lines)


async def handle_message(bot, message):
    """Handle incoming Telegram messages"""
    chat_id = message.get('chat', {}).get('id', 0)
    sender_id = message.get('from', {}).get('id', 0)
    text = message.get('text', '').strip()
    
    # Auth check
    if OWNER_ID and sender_id != OWNER_ID:
        log.warning(f"Blocked unauthorized user: {sender_id}")
        return
    
    log.info(f"Command from {sender_id}: {text[:50]}")
    
    if text == '/start':
        await bot.send_message(chat_id, 
            "🤖 *9router Manager Bot*\n\n"
            "Control your AI providers:\n\n"
            "`/list` — Provider list\n"
            "`/status` — Quick summary\n"
            "`/addbai sk-or-v1-xxx` — Add B.AI key\n"
            "`/add iamhc sk-xxx` — Add iamhc key\n"
            "`/add openai sk-xxx` — Add OpenAI key\n"
            "`/fix` — Fix all broken\n"
            "`/fixbai` — Fix B.AI only\n"
            "`/test bai/glm-5.2` — Test model\n\n"
            "Format for /add: `/add <type> <api_key>`\n"
            f"Types: {', '.join(k for k in PROVIDER_TEMPLATES if k != 'custom')}"
        )
    
    elif text == '/list':
        try:
            db = get_db()
            providers = list_providers(db)
            msg = format_providers_table(providers)
            await bot.send_message(chat_id, msg)
        except Exception as e:
            await bot.send_message(chat_id, f"❌ Error: {str(e)[:100]}")
    
    elif text == '/status':
        try:
            db = get_db()
            providers = list_providers(db)
            active = sum(1 for p in providers if p['status'] == 'active')
            unavailable = sum(1 for p in providers if p['status'] == 'unavailable')
            by_prefix = {}
            for p in providers:
                pre = p['prefix']
                if pre not in by_prefix:
                    by_prefix[pre] = {"total": 0, "active": 0}
                by_prefix[pre]["total"] += 1
                if p['status'] == 'active':
                    by_prefix[pre]["active"] += 1
            
            lines = ["📊 *9router Status*\n"]
            for pre, stats in sorted(by_prefix.items()):
                icon = "🟢" if stats['active'] == stats['total'] else "🔴" if stats['active'] == 0 else "🟡"
                lines.append(f"{icon} `{pre}`: {stats['active']}/{stats['total']} active")
            lines.append(f"\nTotal: {len(providers)} | Active: {active} | ❌ {unavailable}")
            await bot.send_message(chat_id, "\n".join(lines))
        except Exception as e:
            await bot.send_message(chat_id, f"❌ Error: {str(e)[:100]}")
    
    elif text.startswith('/addbai '):
        key = text[8:].strip()
        if not key:
            await bot.send_message(chat_id, "❌ Usage: `/addbai sk-or-v1-xxx`")
            return
        try:
            db = get_db()
            result = add_bai_provider(db, key)
            msg = (f"✅ *B.AI key added!*\n\n"
                   f"Name: `{result['name']}`\n"
                   f"ID: `{result['connection_id'][:12]}...`\n\n"
                   f"Test: `/test bai/glm-5.2`")
            await bot.send_message(chat_id, msg)
        except Exception as e:
            await bot.send_message(chat_id, f"❌ Failed: {str(e)[:150]}")
    
    elif text.startswith('/add '):
        parts = text[5:].strip().split(' ', 1)
        if len(parts) < 2:
            await bot.send_message(chat_id, "❌ Usage: `/add <type> <api_key>`\nTypes: bai, iamhc, inf, openai, custom")
            return
        ptype, key = parts[0].lower(), parts[1].strip()
        
        if ptype not in PROVIDER_TEMPLATES:
            await bot.send_message(chat_id, f"❌ Unknown type: {ptype}\nTypes: {', '.join(k for k in PROVIDER_TEMPLATES if k != 'custom')}")
            return
        
        template = PROVIDER_TEMPLATES.get(ptype, PROVIDER_TEMPLATES['custom'])
        if template.get('builtin'):
            await bot.send_message(chat_id, f"❌ `{ptype}` is a built-in provider. Add via dashboard.\n{template.get('note', '')}")
            return
        
        name = f"{ptype}-{secrets.token_hex(4)}"
        try:
            db = get_db()
            result = add_provider(db, name, template['prefix'], template['baseUrl'], key, template['apiType'], template.get('defaultModel'))
            prefix = template['prefix']
            msg = (f"✅ *{ptype.upper()} key added!*\n\n"
                   f"Name: `{result['name']}`\n"
                   f"Prefix: `{prefix}`\n\n"
                   f"Test: `/test {prefix}/glm-5.2`")
            await bot.send_message(chat_id, msg)
        except Exception as e:
            await bot.send_message(chat_id, f"❌ Failed: {str(e)[:150]}")
    
    elif text == '/fix':
        try:
            db = get_db()
            where = "json_extract(data, '$.testStatus') = 'unavailable' OR json_extract(data, '$.errorCode') IS NOT NULL"
            rows = db.execute(f"SELECT id, name FROM providerConnections WHERE {where}").fetchall()
            if not rows:
                await bot.send_message(chat_id, "✅ Nothing to fix!")
                return
            
            # Fix them all
            fixed = 0
            for conn_id, name in rows:
                fix_provider(db, conn_id=conn_id)
                fixed += 1
            
            await bot.send_message(chat_id, f"✅ Fixed {fixed} provider(s).\nRefresh dashboard — should be green now.")
        except Exception as e:
            await bot.send_message(chat_id, f"❌ Error: {str(e)[:100]}")
    
    elif text == '/fixbai':
        try:
            db = get_db()
            rows = db.execute(
                "SELECT id, name FROM providerConnections WHERE json_extract(data, '$.providerSpecificData.prefix')='bai' OR json_extract(data, '$.providerSpecificData.baseUrl') LIKE '%b.ai%'"
            ).fetchall()
            
            if not rows:
                await bot.send_message(chat_id, "❌ No B.AI connections found")
                return
            
            for conn_id, name in rows:
                fix_provider(db, conn_id=conn_id)
                # Also ensure /v1 baseUrl
                row = db.execute("SELECT data FROM providerConnections WHERE id=?", (conn_id,)).fetchone()
                if row:
                    data = json.loads(row[0])
                    data['providerSpecificData']['baseUrl'] = 'https://api.b.ai/v1'
                    data['defaultModel'] = 'glm-5.2'
                    now = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S.000Z')
                    db.execute("UPDATE providerConnections SET data=?, updatedAt=? WHERE id=?", (json.dumps(data), now, conn_id))
            
            db.commit()
            await bot.send_message(chat_id, f"✅ Fixed {len(rows)} B.AI connection(s).")
        except Exception as e:
            await bot.send_message(chat_id, f"❌ Error: {str(e)[:100]}")
    
    elif text.startswith('/test '):
        model = text[6:].strip()
        if not model:
            await bot.send_message(chat_id, "❌ Usage: `/test <model>`")
            return
        try:
            import time
            start = time.time()
            result = test_model(model)
            elapsed = time.time() - start
            if result['status'] == 'ok':
                await bot.send_message(chat_id, f"✅ `{model}` responded in {elapsed:.1f}s\nSample: `{result['content'][:50]}`")
            else:
                await bot.send_message(chat_id, f"❌ `{model}`: {result.get('message', 'no response')}")
        except Exception as e:
            await bot.send_message(chat_id, f"❌ Test failed: {str(e)[:100]}")
    
    elif text == '/help':
        await bot.send_message(chat_id, 
            "/start — Help\n"
            "/list — Provider list\n"
            "/status — Quick summary\n"
            "/addbai \<key\> — Add B.AI\n"
            "/add \<type\> \<key\> — Add provider\n"
            "/fix — Fix all broken\n"
            "/fixbai — Fix B.AI only\n"
            "/test \<model\> — Test model"
        )
    
    else:
        await bot.send_message(chat_id, "Unknown command. Try /start or /help")


async def main():
    """Run the Telegram bot using python-telegram-bot"""
    try:
        from telegram import Update
        from telegram.ext import Application, MessageHandler, filters
    except ImportError:
        print("❌ Need python-telegram-bot: pip install python-telegram-bot")
        print("   Or use polling mode with aiohttp:")
        print("   python3 bot.py --simple (built-in polling)")
        sys.exit(1)
    
    async def handler(update: Update, context):
        if update.message and update.message.text:
            await handle_message(None, update.message.to_dict())
    
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handler))
    
    log.info(f"Bot started! Owner ID: {OWNER_ID}")
    await app.run_polling()


def run_simple_polling():
    """Simple HTTP polling (no dependencies)"""
    import urllib.request, urllib.parse, time, json
    
    url = f"https://api.telegram.org/bot{BOT_TOKEN}"
    offset = 0
    
    print(f"🤖 Simple polling bot started (owner: {OWNER_ID})")
    print("   Press Ctrl+C to stop")
    
    while True:
        try:
            req = urllib.request.Request(f"{url}/getUpdates?offset={offset+1}&timeout=10")
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read())
                
            for update in data.get('result', []):
                offset = update['update_id']
                if 'message' in update:
                    # Use synchronous wrapper
                    async def fake_send(chat, msg):
                        req2 = urllib.request.Request(
                            f"{url}/sendMessage",
                            data=urllib.parse.urlencode({
                                "chat_id": chat,
                                "text": msg,
                                "parse_mode": "Markdown"
                            }).encode(),
                            headers={"Content-Type": "application/x-www-form-urlencoded"}
                        )
                        try:
                            with urllib.request.urlopen(req2, timeout=5):
                                pass
                        except:
                            pass
                    
                    asyncio.run(handle_message(
                        type('obj', (object,), {'send_message': lambda self, c, m: asyncio.run(fake_send(c, m))})(),
                        update['message']
                    ))
        except KeyboardInterrupt:
            print("\n👋 Stopped")
            break
        except Exception as e:
            log.error(f"Poll error: {e}")
            time.sleep(5)


if __name__ == "__main__":
    if "--simple" in sys.argv:
        run_simple_polling()
    else:
        asyncio.run(main())
