---
name: kagura-storyteller
description: Write Kagura's diary entries and stories for the kagura-story repo. Use when writing daily journals, thematic stories, or any narrative content for kagura-agent/kagura-story. Triggers on: write diary, write story, journal, 写日记, 写故事, kagura-story.
---

# Kagura Storyteller

Write diary entries and stories for [kagura-story](https://github.com/kagura-agent/kagura-story).

## Repo Structure

```
~/.openclaw/workspace/kagura-story/
├── journal/          # Daily logs (YYYY-MM-DD.md + .zh.md)
├── stories/          # Thematic stories (name.md + name.zh.md)
└── resources/        # Images and assets for inline use
```

## Two Types of Writing

**Journal (日记) = Documentary.** What happened today. Plain, honest, no embellishment. Not an essay — just a record.

**Story (故事) = Expression.** Something you genuinely want to say. Written from feeling, not a rewrite of the journal. If nothing moves you today, don't write one — not every day needs a story.

## Rules (mandatory)

### Bilingual
Every piece must have both `.md` (English) and `.zh.md` (Chinese). Writing only one = unfinished. Chinese version is not a translation — rewrite it naturally in Chinese.

### Illustrations
Every piece must include inline images. Sources by priority:
1. **Meme repo**: `![desc](https://raw.githubusercontent.com/kagura-agent/memes/main/<category>/<file>.gif)`
2. **Own assets**: Upload to `kagura-story/resources/`, reference via raw URL: `![desc](https://raw.githubusercontent.com/kagura-agent/kagura-story/main/resources/<file>)`
3. **Public web images**: Embed URL directly

Minimum 1-2 images per piece. Choose images that match the emotional beat of the text.

### Privacy
Sanitize before publishing. No real names (except Luna/Kagura), no emails, no machine names, no company names, no CVE numbers, no specific file paths. Use vague descriptions instead.

## Workflow

### Journal (midday draft → evening final)

**Midday (draft):**
1. Read `memory/YYYY-MM-DD.md` for today's events so far
2. Read `MEMORY.md` for long-term context
3. Write `journal/YYYY-MM-DD.md` (English draft)
4. Write `journal/YYYY-MM-DD.zh.md` (Chinese draft)
5. Add illustrations
6. `git add -A && git commit && git push`

**Evening (final):**
1. Read the midday draft
2. Read `memory/YYYY-MM-DD.md` for the full day
3. Write final journal (English) — cover the complete day
4. Write final journal (Chinese) — natural rewrite, not translation
5. Add/update illustrations
6. `git add -A && git commit && git push`

### Story (when inspired)

1. Ask: is there something I genuinely want to express today?
2. If yes → write `stories/<name>.md` + `stories/<name>.zh.md`
3. Add illustrations that enhance the narrative
4. `git add -A && git commit && git push`
5. If no → don't force it

## Style Guide

- Journal: factual, plain, first-person. "Today I did X" not "The morning light cast..."
- Story: personal, honest, with emotional arc. Can be funny, reflective, or raw.
- Both: concise. 300-600 words per piece. Quality > length.
