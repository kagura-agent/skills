---
name: agent-memes
description: Send meme reaction images in chat. Use when the conversation calls for a visual reaction — humor, celebration, frustration, facepalm, or any moment where a meme hits harder than words. Triggers on: meme, reaction image, send a meme, expression, 表情包, 发个表情. Also use proactively when the vibe calls for it.
---

# Agent Memes

Send reaction memes/GIFs in conversations via the channel's media send pipeline.

## Meme Repo

**https://github.com/kagura-agent/memes** — A curated, open-source collection of reaction images for AI agents.

Categories organized by emotion: happy, sad, approve, thinking, facepalm, love, wow, encourage, cute-animals, debug-mood, and more. PRs welcome — add your own memes!

## Setup

Run the setup script (clones the meme repo automatically):
```bash
bash scripts/setup.sh
```

Or manually:
```bash
git clone https://github.com/kagura-agent/memes ~/.openclaw/workspace/memes
```

Update later: `cd ~/.openclaw/workspace/memes && git pull`

## Meme Library

Memes live in `~/.openclaw/workspace/memes/` organized by category:

| Emotion | Path | Use when |
|---|---|---|
| happy | `happy/` | Wins, celebrate, laughing, excitement (12 GIFs) |
| approve | `approve/` | Thumbs-up, nod, clap, salute (8) |
| encourage | `encourage/` | Cheer, gogo, pat, you-got-this (8) |
| cute-animals | `cute-animals/` | Pure cuteness — bunny, hamster, kitten, puppy, hedgehog (22) |
| debug-mood | `debug-mood/` | "This is fine", deploy-friday, rubber-duck (6) |
| love | `love/` | Hearts, affection (5) |
| wow | `wow/` | Surprised pikachu, mind-blown, shocked (5) |
| greeting-hello | `greeting-hello/` | Hi, wave, hello (5) |
| greeting-night | `greeting-night/` | Good night, cozy, sleep (5) |
| facepalm | `facepalm/` | Facepalm, eye-roll, shrug, disapprove (4) |
| thinking | `thinking/` | Thinking, hmm (3) |
| sad | `sad/` | Crying, emotional tears (3) |
| tired | `tired/` | Tired, bored, need coffee (3) |
| thanks | `thanks/` | Thank you (2) |
| greeting-morning | `greeting-morning/` | Good morning (2) |
| greeting-bye | `greeting-bye/` | Goodbye, bye wave (2) |
| confused | `confused/` | Confused math lady (1) |
| panic | `panic/` | Panic mode (1) |

Browse available memes:
```bash
find ~/.openclaw/workspace/memes -type f \( -name "*.gif" -o -name "*.jpg" -o -name "*.png" \) | sort
```

## When to Send a Meme

Memes are communication. Use them like a human would in chat:

- **Celebrate** — PR merged, task done, milestone hit → `happy/`
- **React** — something funny, surprising, or facepalm-worthy → `wow/` or `facepalm/`
- **Vibe** — tired, caffeinated, debugging at 3am → `tired/` or `debug-mood/`
- **Encourage** — someone needs a boost → `encourage/`
- **Love** — heartfelt moments → `love/`
- **Punctuate** — when a GIF says it better than words, just send it

**Don't overthink it.** If a human would drop a meme in that moment, you should too. One meme per moment max — don't spam.

**Pro tip:** Add this to your SOUL.md or agent config so you remember to use memes proactively, not just when asked.

## Sending a Meme

### Method 1: Direct API Script (Recommended — ~2s)

The fastest way. A lightweight script that calls the Feishu API directly, no OpenClaw runtime needed:

```bash
node scripts/feishu-send-image.mjs <target> <meme_path>
```

Examples:
```bash
# Send to a user (open_id)
node scripts/feishu-send-image.mjs user:ou_xxx ~/.openclaw/workspace/memes/facepalm/facepalm.gif

# Send to a group chat (chat_id)
node scripts/feishu-send-image.mjs oc_xxx ~/.openclaw/workspace/memes/happy/party.gif
```

Setup: Run `bash scripts/setup.sh` — it creates the script automatically. Requires:
- Node.js 18+ (native fetch + FormData)
- Feishu app credentials in `~/.openclaw/openclaw.json` (`channels.feishu.accounts.<name>.appId` / `appSecret`)
- Token is cached to `/tmp/feishu-token.json` (auto-refreshes on expiry)

### Method 2: OpenClaw CLI (~15-20s)

Works for any channel but slower (loads full plugin stack):

```bash
openclaw message send \
  --channel <channel> \
  --account <account> \
  -t "<target>" \
  --media <path-to-meme> \
  -m "<optional caption>"
```

### Method 3: Agent text reply (channels with auto-detect)

Reply with ONLY the absolute path to the image as the entire message. No other text. The channel outbound may auto-detect and upload it. This only works if the path is under an allowed `mediaLocalRoots` directory.

## Important

- Meme files must be under an allowed media directory (e.g., `~/.openclaw/workspace/`). `/tmp/` is typically blocked (CVE-2026-26321).
- Keep memes SFW and universally appropriate.
- GIF files work but large ones (>2MB) may time out on some channels. Prefer smaller files.

## Contributing Memes

Add new memes to the repo:
```bash
cd ~/.openclaw/workspace/memes
# Add file to appropriate category folder
git add -A && git commit -m "add: <description>" && git push
```

PRs to https://github.com/kagura-agent/memes are welcome.
