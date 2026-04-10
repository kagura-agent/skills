---
name: discord-ops
description: "Discord server management. Use when: creating channels, managing pins, updating allowlists, configuring cron delivery targets, or any Discord infrastructure task. Triggers on: create channel, discord channel, pin message, discord管理, 建channel, discord ops."
---

# Discord Ops

Manage a Discord workspace — channels, pins, allowlists, cron routing.

## Prerequisites

- Bot token in env var (e.g. `$DISCORD_BOT_TOKEN`)
- Proxy if needed (e.g. `$https_proxy`)
- Guild ID, channel IDs → check `TOOLS.md` for your specific setup

All API calls need:
```
-H "Authorization: Bot $DISCORD_BOT_TOKEN"
-H "User-Agent: DiscordBot (https://openclaw.ai, 1.0)"
```

## Create Channel

Four steps, don't skip any:

```bash
# 1. Create via API (set parent_id to put it in a category!)
curl -s -X POST "https://discord.com/api/v10/guilds/GUILD_ID/channels" \
  -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -H "User-Agent: DiscordBot (https://openclaw.ai, 1.0)" \
  -d '{"name": "CHANNEL_NAME", "type": 0, "parent_id": "CATEGORY_ID", "topic": "DESCRIPTION"}'

# 2. Add to allowlist in openclaw.json (groupPolicy: allowlist)
# → Read config first, edit the guild's channels object, write back

# 3. Send + pin initial tracker message

# 4. Restart gateway (allowlist changes need restart)
openclaw gateway restart
```

## Update Pin Content

```bash
curl -s -X PATCH "https://discord.com/api/v10/channels/CHANNEL_ID/messages/MESSAGE_ID" \
  -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -H "User-Agent: DiscordBot (https://openclaw.ai, 1.0)" \
  -d '{"content": "NEW CONTENT"}'
```

## Auto-Sync Pins (Hook Pattern)

Use a `message:sent` hook to monitor file mtime → auto-update pins:
- Watch file changes with `fs.statSync(path).mtimeMs`
- Debounce 3s to batch rapid changes
- PATCH Discord pin via API
- See `hooks/todo-pin-sync/` for reference implementation

## Cron Delivery to Channel

```json
{
  "delivery": {
    "mode": "announce",
    "channel": "discord",
    "to": "channel:CHANNEL_ID",
    "accountId": "YOUR_ACCOUNT",
    "bestEffort": true
  }
}
```

## Rules & Gotchas

- **Always include `parent_id`** — without it, channel appears outside any category
- **Always add to allowlist** before expecting bot to respond (if using `groupPolicy: allowlist`)
- **Always restart gateway** after allowlist changes — config is not hot-reloaded for channels
- **Cron config IS hot-reloaded** — no restart needed for cron changes
- **Pin limit**: 50 per channel
- **Keep pins clean**: one tracker/status pin per channel
- **Record new channel IDs** in TOOLS.md for future reference
