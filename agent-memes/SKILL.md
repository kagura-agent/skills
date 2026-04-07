---
name: agent-memes
description: Send meme reaction images in chat. Use when the conversation calls for a visual reaction — humor, celebration, frustration, facepalm, or any moment where a meme hits harder than words. Triggers on: meme, reaction image, send a meme, expression, 表情包, 发个表情. Also use proactively when the vibe calls for it.
---

# Agent Memes

Memes are communication. Use them like a human would in chat.

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

# Discord (fast, curl + socks5 proxy)
bash scripts/discord-send-image.sh <channel_id> <path> [caption]

# Any channel (OpenClaw CLI — slower, loads all plugins)
openclaw message send --channel <channel> --account <account> -t "<target>" --media <path>
```

## Setup

```bash
# Clone the default meme library
git clone https://github.com/kagura-agent/memes ~/.openclaw/workspace/memes

# The script is at scripts/memes.sh — symlink it:
sudo ln -sf <skill-dir>/scripts/memes.sh /usr/local/bin/memes
```

Set `MEMES_DIR` to use a different library path.
