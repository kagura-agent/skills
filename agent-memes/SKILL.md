---
name: agent-memes
description: Send meme reaction images in chat. Use when the conversation calls for a visual reaction — humor, celebration, frustration, facepalm, or any moment where a meme hits harder than words. Triggers on: meme, reaction image, send a meme, expression, 表情包, 发个表情. Also use proactively when the vibe calls for it.
---

# Agent Memes

Send reaction memes/GIFs in conversations via the channel's media send pipeline.

## Meme Repo

**https://github.com/kagura-agent/memes** — A curated, open-source collection of reaction images for AI agents.

Categories: reactions, cats, celebrate, debug, mood. PRs welcome — add your own memes!

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

| Category | Path | Use when |
|---|---|---|
| reactions | `reactions/` | General reactions — thumbs-up, facepalm, thinking, surprised-pikachu, shrug |
| cats | `cats/` | Cat moments — typing, vibing, grumpy, stare |
| celebrate | `celebrate/` | Wins, merges, milestones, high-fives |
| debug | `debug/` | "This is fine" energy, deploy-friday, rubber-duck, stack-overflow |
| mood | `mood/` | Coffee, tired, excited, bored, panic |

Browse available memes:
```bash
find ~/.openclaw/workspace/memes -type f \( -name "*.gif" -o -name "*.jpg" -o -name "*.png" \) | sort
```

## When to Send a Meme

Memes are communication. Use them like a human would in chat:

- **Celebrate** — PR merged, task done, milestone hit → `celebrate/`
- **React** — something funny, surprising, or facepalm-worthy → `reactions/`
- **Vibe** — tired, caffeinated, debugging at 3am → `mood/` or `debug/`
- **Punctuate** — when a GIF says it better than words, just send it

**Don't overthink it.** If a human would drop a meme in that moment, you should too. One meme per moment max — don't spam.

**Pro tip:** Add this to your SOUL.md or agent config so you remember to use memes proactively, not just when asked.

## Sending a Meme

### Via OpenClaw CLI (works for any channel)

```bash
openclaw message send \
  --channel <channel> \
  --account <account> \
  -t "<target>" \
  --media <path-to-meme> \
  -m "<optional caption>"
```

### Via agent text reply (channels with auto-detect)

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
