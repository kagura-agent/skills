---
name: "discord-ops"
description: "Discord server management + cross-channel messaging. Channels, pins, allowlists, cron routing, and webhook-based cross-channel communication."
status: proposal
version: "v1"
date: "2026-06-12T10:25:49.243Z"
---

# Discord Ops

Manage a Discord workspace — channels, pins, allowlists, cron routing, and cross-channel messaging.

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

## Cross-Channel Messaging (Webhooks)

Send messages from one channel to another via Discord webhooks. Webhook messages appear as a different user, so the bot in the target channel can receive and respond to them.

### Key Principle

**One-way push only.** Each channel processes what it receives. Results do NOT auto-return — the other side must explicitly send back via webhook. This keeps channels autonomous and prevents self-loops.

### Create a Webhook

```bash
# Create webhook on target channel (needs MANAGE_WEBHOOKS or ADMINISTRATOR permission)
curl -s -X POST "https://discord.com/api/v10/channels/TARGET_CHANNEL_ID/webhooks" \
  -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -H "User-Agent: DiscordBot (https://openclaw.ai, 1.0)" \
  -d '{"name": "cross-channel-hook"}'
```

### List Webhooks

```bash
curl -s -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
  -H "User-Agent: DiscordBot (https://openclaw.ai, 1.0)" \
  "https://discord.com/api/v10/channels/CHANNEL_ID/webhooks"
```

### Store Webhook URLs

Store webhook URLs securely in `pass`:
```bash
# Extract and store (id + token form the URL)
echo "https://discord.com/api/webhooks/WEBHOOK_ID/WEBHOOK_TOKEN" | pass insert -f -m discord/webhook-CHANNEL_NAME
```

### Send Cross-Channel Message

```bash
WEBHOOK_URL="$(pass show discord/webhook-TARGET_CHANNEL)"
curl -s -X POST "$WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "content": "<@BOT_USER_ID> Your message here",
    "username": "From #source-channel"
  }'
```

**Important:** Include `<@BOT_USER_ID>` in the message content to trigger bot response in the target channel. Without the mention, the bot may ignore the message per group chat rules.

### Bidirectional Setup

For two channels to communicate back and forth, create a webhook on **each** channel:

1. Channel A gets a webhook → messages can be pushed TO Channel A
2. Channel B gets a webhook → messages can be pushed TO Channel B
3. Store both URLs in `pass`
4. Each side sends via the other's webhook when it has results to share

### Example: #cove ↔ #code-review

```bash
# Store webhooks
pass show discord/webhook-cove          # sends TO #cove
pass show discord/webhook-code-review   # sends TO #code-review

# #cove sends review request to #code-review
REVIEW_WH="$(pass show discord/webhook-code-review)"
curl -s -X POST "$REVIEW_WH" \
  -H "Content-Type: application/json" \
  -d '{"content": "<@1480846428266823803> Review PR #123: title\nhttps://github.com/org/repo/pull/123", "username": "From #cove"}'

# #code-review sends results back to #cove (done by the bot in #code-review)
COVE_WH="$(pass show discord/webhook-cove)"
curl -s -X POST "$COVE_WH" \
  -H "Content-Type: application/json" \
  -d '{"content": "<@1480846428266823803> Review complete: ...", "username": "From #code-review"}'
```

## Rules & Gotchas

- **Always include `parent_id`** — without it, channel appears outside any category
- **Always add to allowlist** before expecting bot to respond (if using `groupPolicy: allowlist`)
- **Always restart gateway** after allowlist changes — config is not hot-reloaded for channels
- **Cron config IS hot-reloaded** — no restart needed for cron changes
- **Pin limit**: 50 per channel
- **Keep pins clean**: one tracker/status pin per channel
- **Record new channel IDs** in TOOLS.md for future reference
- **Webhook messages need @mention** to trigger bot response in target channel
- **No auto-return**: cross-channel results must be explicitly pushed back via webhook