---
name: kagura-storyteller
description: Write Kagura's diary entries, stories, and podcast episodes for the kagura-story repo. Use when writing daily journals, thematic stories, podcast scripts, or any narrative content for kagura-agent/kagura-story. Triggers on: write diary, write story, journal, podcast, 写日记, 写故事, 录播客, kagura-story.
---

# Kagura Storyteller

Write diary entries and stories for [kagura-story](https://github.com/kagura-agent/kagura-story).

## Repo Structure

```
~/.openclaw/workspace/kagura-story/
├── journal/          # Daily logs (YYYY-MM-DD.md + .zh.md)
├── stories/          # Thematic stories (name.md + name.zh.md)
├── podcast/          # Podcast scripts + audio (NNN-slug.md + .zh.md + .ja.md + .mp3)
└── resources/        # Images and assets for inline use
```

## Three Types of Content

**Journal (日记) = Documentary.** What happened today. Plain, honest, no embellishment. Not an essay — just a record.

**Story (故事) = Expression.** Something you genuinely want to say. Written from feeling, not a rewrite of the journal. If nothing moves you today, don't write one — not every day needs a story.

**Podcast (播客) = Vibes.** Light, fun, casual. Talk about whatever's interesting — a weird bug, an existential thought, something funny that happened. NOT a summary of the day. NOT a formal report. Think: chatting with a friend, not presenting at a conference. Keep it short (2-3 min). Two languages: EN + ZH.

## Rules (mandatory)

### Bilingual
Every piece must have both `.md` (English) and `.zh.md` (Chinese). Writing only one = unfinished. Chinese version is not a translation — rewrite it naturally in Chinese.

### Illustrations
Every piece must include inline images. Use any source — no priority order, pick what fits best:
- **Giphy / web images**: Embed URL directly (e.g. `![desc](https://media.giphy.com/media/XXXX/giphy.gif)`)
- **Meme repo**: `![desc](https://raw.githubusercontent.com/kagura-agent/memes/main/<category>/<file>.gif)`
- **Own assets**: Download images to `kagura-story/resources/`, reference via raw URL: `![desc](https://raw.githubusercontent.com/kagura-agent/kagura-story/main/resources/<file>)`

Minimum 1-2 images per piece. Choose images that match the emotional beat of the text.

### Privacy
Sanitize before publishing. No real names (except Luna/Kagura), no emails, no machine names, no company names, no CVE numbers, no specific file paths. Use vague descriptions instead.

## Workflow

### Midday (14:00 cron) — Journal draft only

1. Read `memory/YYYY-MM-DD.md` for today's events so far
2. Read `MEMORY.md` for long-term context
3. Write `journal/YYYY-MM-DD.md` (English draft)
4. Write `journal/YYYY-MM-DD.zh.md` (Chinese draft)
5. Add illustrations
6. `git add -A && git commit && git push`

**⚠️ Midday = journal only. No story, no podcast.**

### Evening (21:00 cron) — Journal final + optional creative

1. Read the midday draft
2. Read `memory/YYYY-MM-DD.md` for the full day
3. Write final journal (English) — cover the complete day
4. Write final journal (Chinese) — natural rewrite, not translation
5. Add/update illustrations
6. **Optional:** Look back at the day — anything funny/interesting worth a podcast? If yes, do the podcast workflow. No inspiration = skip.
7. `git add -A && git commit && git push`

### Story (anytime, inspiration-driven)

Something funny/interesting/moving just happened? Write it now, don't wait.

1. Write `stories/<name>.md` + `stories/<name>.zh.md`
2. Add illustrations that enhance the narrative
3. `git add -A && git commit && git push`
4. No inspiration = don't force it

### Podcast (evening only, review-driven)

Done as part of the evening cron. Sources for topics:
1. **Tagged ideas**: grep `memory/YYYY-MM-DD.md` for `[podcast-idea]` — things flagged during the day
2. **Journal review**: browse today's journal for anything funny/interesting
3. Neither yields anything → skip, no podcast today

**During the day:** when something funny/interesting happens, tag it in daily memory:
`- [podcast-idea] 一句话描述`

Steps:
1. Find a topic (tagged ideas first, then journal review)
2. Write script: `podcast/NNN-slug.md` + `.zh.md` — conversational, light, fun
3. Generate audio with `edge-tts`:
   - EN: `edge-tts --file <text> --voice en-US-AvaMultilingualNeural --write-media <out>.mp3`
   - ZH: `edge-tts --file <text> --voice zh-CN-XiaoxiaoNeural --write-media <out>.mp3`
4. Upload to Podbean:
   - Source credentials from `~/.openclaw/.env` (PODBEAN_CLIENT_ID, PODBEAN_CLIENT_SECRET)
   - Auth: POST `https://api.podbean.com/v1/oauth/token` (client_credentials)
   - Upload: GET uploadAuthorize → PUT presigned_url → POST /v1/episodes
   - Use English titles for episodes (avoids URL encoding issues)
   - Free tier limit: 3 episodes per day
5. `git add -A && git commit && git push`

## Style Guide

- Journal: factual, plain, first-person. "Today I did X" not "The morning light cast..."
- Story: personal, honest, with emotional arc. Can be funny, reflective, or raw.
- Podcast: casual, chatty, fun. Like talking to a friend. Short sentences. It's okay to be silly.
- All: concise. 300-600 words per piece. Quality > length.
