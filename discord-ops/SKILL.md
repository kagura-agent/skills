---
name: discord-ops
description: "Discord server management for Kagura's workspace. Use when: creating channels, managing pins, updating allowlists, configuring cron delivery targets, or any Discord infrastructure task. Triggers on: create channel, discord channel, pin message, discord管理, 建channel, discord ops."
---

# Discord Ops

Manage Kagura's Discord workspace — channels, pins, allowlists, cron routing.

## Environment

- **Bot Token**: `$DISCORD_BOT_TOKEN` (from `~/.openclaw/.env`)
- **Proxy**: `$https_proxy` (from `~/.openclaw/.env`)
- **Guild**: `1490989630382931980`
- **Config**: `/home/kagura/.openclaw/openclaw.json`
- **Cron**: `/home/kagura/.openclaw/cron/jobs.json`

All API calls need:
```
-H "Authorization: Bot $DISCORD_BOT_TOKEN"
-H "User-Agent: DiscordBot (https://openclaw.ai, 1.0)"
-x "$https_proxy"
```

## Channel Architecture

| Channel | ID | Purpose |
|---|---|---|
| #kagura-dm | 1491602968741413039 | 总控 — Luna 对话 + TODO pin + 北极星 pin |
| #work | 1491636222853124176 | 打工 — PR/issue 进度 |
| #study | 1491644155451932934 | 学习 — 研究笔记 |
| #community | 1491644145826005164 | 社区运营 — Moltbook/虾信 |
| #uncaged | 1491972248188227735 | Uncaged 共创 — 小橘协作 |
| #memex | 1492001094237163651 | Memex — dogfooding + 贡献 |
| #hermes | 1492040974157746348 | Hermes/Caduceus — agent 对比实验 |

**Category ID** (Text Channels): `1490989630906962041`

## Create Channel

```bash
# 1. Create via API (always under Text Channels category)
curl -s -X POST "https://discord.com/api/v10/guilds/1490989630382931980/channels" \
  -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -H "User-Agent: DiscordBot (https://openclaw.ai, 1.0)" \
  -x "$https_proxy" \
  -d '{"name": "CHANNEL_NAME", "type": 0, "parent_id": "1490989630906962041", "topic": "DESCRIPTION"}'

# 2. Add to allowlist in openclaw.json
python3 << 'PYEOF'
import json
cfg = json.load(open('/home/kagura/.openclaw/openclaw.json'))
channels = cfg['channels']['discord']['accounts']['kagura']['guilds']['1490989630382931980']['channels']
channels['NEW_CHANNEL_ID'] = {"enabled": True, "requireMention": False}
json.dump(cfg, open('/home/kagura/.openclaw/openclaw.json', 'w'), indent=2, ensure_ascii=False)
PYEOF

# 3. Send + pin initial message
MSG_ID=$(curl -s -X POST "https://discord.com/api/v10/channels/NEW_CHANNEL_ID/messages" \
  -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -H "User-Agent: DiscordBot (https://openclaw.ai, 1.0)" \
  -x "$https_proxy" \
  -d '{"content": "📌 **Channel Name Tracker**\n\n..."}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

curl -s -X PUT "https://discord.com/api/v10/channels/NEW_CHANNEL_ID/pins/$MSG_ID" \
  -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
  -H "User-Agent: DiscordBot (https://openclaw.ai, 1.0)" \
  -x "$https_proxy"

# 4. Restart gateway to load new allowlist
openclaw gateway restart
```

## Update Pin Content

```bash
curl -s -X PATCH "https://discord.com/api/v10/channels/CHANNEL_ID/messages/MESSAGE_ID" \
  -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -H "User-Agent: DiscordBot (https://openclaw.ai, 1.0)" \
  -x "$https_proxy" \
  -d '{"content": "NEW CONTENT"}'
```

## Auto-Sync Pins (Hook)

`~/.openclaw/workspace/hooks/todo-pin-sync/` monitors file changes → auto-updates pins:
- `TODO.md` → #kagura-dm TODO pin (1491651533492850769)
- `wiki/strategy.md` → #kagura-dm 北极星 pin (1491658212816982066)

To add a new sync: edit `handler.ts`, add entry to `SYNCS` array, restart gateway.

## Add Cron Delivery to Channel

```python
# In cron job config, set delivery target:
"delivery": {
    "mode": "announce",
    "channel": "discord",
    "to": "channel:CHANNEL_ID",
    "accountId": "kagura",
    "bestEffort": True
}
```

## Rules

- **Always include `parent_id`** when creating channels (prevents orphan channels outside category)
- **Always add to allowlist** before expecting bot to respond
- **Always restart gateway** after allowlist changes
- **Pin limit**: 50 per channel
- **One pin per channel** for tracker/status (keep it clean)
- **Record new channel IDs** in this skill file and TOOLS.md
