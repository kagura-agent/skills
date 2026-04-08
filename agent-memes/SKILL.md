---
name: agent-memes
version: 1.3.0
description: Send meme reaction images in chat. Use when the conversation calls for a visual reaction — humor, celebration, frustration, facepalm, or any moment where a meme hits harder than words. Triggers on: meme, reaction image, send a meme, expression, 表情包, 发个表情. Also use proactively when the vibe calls for it.
---

# Agent Memes

Memes are communication. Use them like a human would in chat.

## ⚠️ Credentials Notice

The sending scripts need API credentials to deliver images:

- **Feishu**: `FEISHU_APP_ID` + `FEISHU_APP_SECRET` env vars (or reads from `~/.openclaw/openclaw.json`)
- **Discord**: `DISCORD_BOT_TOKEN` env var (or reads from `~/.openclaw/openclaw.json`)
- **Telegram**: `TELEGRAM_BOT_TOKEN` env var (or reads from `~/.openclaw/openclaw.json`)
- **Slack**: `SLACK_BOT_TOKEN` env var (or reads from `~/.openclaw/openclaw.json`)
- **WhatsApp**: `WHATSAPP_TOKEN` + `WHATSAPP_PHONE_ID` env vars (or reads from `~/.openclaw/openclaw.json`)
- **WeChat (企业微信)**: `WECHAT_CORP_ID` + `WECHAT_CORP_SECRET` + `WECHAT_AGENT_ID` env vars (or reads from `~/.openclaw/openclaw.json`)
- **QQ Bot**: `QQ_BOT_TOKEN` + `QQ_BOT_APPID` env vars (or reads from `~/.openclaw/openclaw.json`)
- **LINE**: `LINE_CHANNEL_ACCESS_TOKEN` env var (or reads from `~/.openclaw/openclaw.json`)

The `memes pick` CLI itself needs **no credentials** — it just picks a local file.

If you only use `memes pick` + your own sending method, no credentials are accessed.

## Quick Start

```bash
memes pick happy        # randomly pick a meme, get its path
memes categories        # see what's available
```

## When to Use

- **Celebrate** — PR merged, task done, milestone → `memes pick happy`
- **React** — something funny, surprising, facepalm-worthy → `memes pick wow` or `memes pick facepalm`
- **Vibe** — tired, debugging at 3am → `memes pick tired` or `memes pick debug-mood`
- **Encourage** — someone needs a boost → `memes pick encourage`
- **Greet** — morning, night, hello, bye → `memes pick greeting-morning`

**Don't overthink it.** If a human would drop a meme in that moment, you should too.

## Sending

After `memes pick` gives you a path, send it through your channel:

```bash
# Feishu (fast, direct API)
node scripts/feishu-send-image.mjs <target> <path>

# Discord (fast, direct API via curl)
bash scripts/discord-send-image.sh <channel_id> <path> [caption]

# Telegram
bash scripts/telegram-send-image.sh <chat_id> <path> [caption]

# Slack
bash scripts/slack-send-image.sh <channel_id> <path> [caption]

# WhatsApp
bash scripts/whatsapp-send-image.sh <recipient_phone> <path> [caption]

# WeChat (企业微信)
bash scripts/wechat-send-image.sh <userid> <path> [caption]

# QQ Bot
bash scripts/qq-send-image.sh <channel_id> <path> [caption]

# LINE (image must be a public https URL)
bash scripts/line-send-image.sh <user_or_group_id> <image_url> [caption]

# Any channel (OpenClaw CLI — slower, loads all plugins)
openclaw message send --channel <channel> --account <account> -t "<target>" --media <path>
```

### Multi-agent setup

On a gateway with multiple agents, set the account name so each agent uses its own credentials:

```bash
# Feishu
FEISHU_ACCOUNT=myagent node scripts/feishu-send-image.mjs <target> <path>

# Discord
DISCORD_ACCOUNT=myagent bash scripts/discord-send-image.sh <channel_id> <path>
```

Single-agent setups don't need this — the first account in `openclaw.json` is used automatically.

### Proxy (Discord)

If Discord API is blocked, set a proxy:

```bash
DISCORD_PROXY=socks5h://127.0.0.1:1080 bash scripts/discord-send-image.sh ...
```

Also respects `https_proxy` / `HTTPS_PROXY` environment variables.

## Setup

1. **Get a meme library** (or bring your own):
```bash
# LFS is required — memes repo stores images via Git LFS
git lfs install  # one-time setup if you haven't used LFS before
git clone https://github.com/kagura-agent/memes "$MEMES_DIR"
```
`MEMES_DIR` defaults to `~/.openclaw/workspace/memes` if not set.

> ⚠️ If images show as small text files (~130 bytes), LFS didn't pull. Run:
> ```bash
> cd "$MEMES_DIR" && git lfs pull
> ```

2. **Make the CLI available** (choose one):
```bash
# Option A: symlink to your user bin
ln -sf <skill-dir>/scripts/memes.sh ~/.local/bin/memes

# Option B: just call it directly
bash <skill-dir>/scripts/memes.sh pick happy
```

No system-level changes required. No modifications to SOUL.md or other DNA files needed.
