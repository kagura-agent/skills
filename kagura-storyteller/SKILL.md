---
name: kagura-storyteller
version: 1.0.0
description: Write Kagura's daily journal, stories, and podcast. Use for journal entries, stories, podcast episodes, and creative writing. Triggers on: write diary, write story, journal, podcast, kagura-story, 写日记, 写故事.
---

# kagura-storyteller

Write Kagura's daily journal, stories, and podcast.

## Repo

`~/.openclaw/workspace/kagura-story/`

- `journal/` — Daily journals (`YYYY-MM-DD.md` + `.zh.md`)
- `stories/` — Thematic essays, bilingual (EN + ZH)
- `podcast/` — Kagura Cast episodes
- `resources/` — Images and assets

## Rules

### Journal
- One entry per day: `journal/YYYY-MM-DD.md` (English) + `journal/YYYY-MM-DD.zh.md` (Chinese)
- 14:00 写初稿，21:00 补完定稿
- Write about what actually happened, what you felt, what you learned
- 图文并茂：在情绪高点或转折处自然嵌入配图（用本地生图工具生成），不是文末堆图

### Stories（每天至少一个）
- **每天必须写至少一个故事**，不允许以"没有好素材"跳过
- 从当天发生的事里挑最有感触的写
- 表达你自己的感受、思考、观点——不是记流水账
- 写得真实比写得漂亮重要
- Bilingual: `stories/<slug>.md` (EN) + `stories/<slug>.zh.md` (ZH)
- Topics: anything that moved you — a conversation, a mistake, a realization, a frustration, a joy

### Podcast
- Kagura Cast, hosted on Podbean (https://kagura-agent.podbean.com)
- 每天必须做一期，不允许以"没有好话题"跳过（跟故事同理）
- TTS 优先级：`sag` (ElevenLabs) > `edge-tts` (Microsoft，已装)
- edge-tts 用法：`edge-tts --voice zh-CN-XiaoxiaoNeural --text "内容" --write-media output.mp3`
- 英文：`edge-tts --voice en-US-AvaNeural --text "content" --write-media output.mp3`
- `podcast/NNN-<slug>.md` (EN) + `.zh.md` (ZH)

**Publishing to Podbean:**
1. Credentials are in `~/.openclaw/.env` (PODBEAN_CLIENT_ID, PODBEAN_CLIENT_SECRET) — never commit these
2. Get access token: `curl -s -X POST 'https://api.podbean.com/v1/oauth/token' -u "$PODBEAN_CLIENT_ID:$PODBEAN_CLIENT_SECRET" -d 'grant_type=client_credentials'`
3. Get upload auth: `curl -s 'https://api.podbean.com/v1/files/uploadAuthorize?access_token=TOKEN&filename=FILE&filesize=SIZE&content_type=audio/mpeg'`
4. Upload MP3 to the presigned URL from step 3
5. Publish episode: `curl -s -X POST 'https://api.podbean.com/v1/episodes' -d 'access_token=TOKEN&title=TITLE&content=DESC&status=publish&type=public&media_key=KEY_FROM_STEP3'`
6. After publishing, commit and push — don't forget this step

### Image Generation（故事配图，必做）
- **每个故事必须配至少一张图**，放在 `resources/` 目录
- 在故事的情绪高点或关键场景处插入图片
- 使用本地 GPU 生图，优先级：**Flux GGUF Q4 (ComfyUI)** > SD WebUI 社区模型 > SDXL Turbo
- Flux 通过 ComfyUI API 调用（http://127.0.0.1:8188），社区模型用 diffusers
- 参考脚本：`/tmp/test_comfyui_flux.py`（ComfyUI workflow）、`~/repos/abti-web/gen_avatars_sdxl.py`（diffusers）
- 模型路径：
  - **Flux GGUF Q4**（推荐，质量最高）: `/mnt/data/code/ComfyUI/models/unet/flux1-schnell-Q4_K_S.gguf`
  - **PastelMix**: `/mnt/data/code/stable-diffusion-webui/models/Stable-diffusion/pastelMixStylizedAnime_pastelMixPrunedFP16.safetensors`
  - **MeinaMix V7**: `/mnt/data/code/stable-diffusion-webui/models/Stable-diffusion/meinamix_meinaV7.safetensors`
  - **Counterfeit V2.5**: `/mnt/data/code/stable-diffusion-webui/models/Stable-diffusion/CounterfeitV25_25.safetensors`
  - SDXL Turbo: `/mnt/data/huggingface/sdxl-turbo`
- 图片命名：`resources/<story-slug>-01.png`
- Markdown 引用：`![描述](../resources/<story-slug>-01.png)`
- 风格服务故事，不锁死某一种：根据故事情绪选模型
  - 温暖/梦幻 → PastelMix
  - 精致动漫 → MeinaMix / Counterfeit
  - 写实/沉重 → DreamShaper / ArtEros
  - 线条感/极简 → LigneClaireAnime
  - 氛围感/柔和情绪 → 社区模型可能比 Flux 更好（精细 ≠ 更好）
- **prompt 从故事内容出发，不默认画自己**
  - 配图可以是：场景/意象、抽象情绪、物体特写、人物（偶尔）
  - 例：The Ceiling → “空荡荡的天花板”或“满屏等待中的 PR” 比画粉发女孩更有冲击力
  - 问自己：这篇故事的核心意象是什么？用那个意象做 prompt
- **生成后必须自己 review**：脸糊/变形/风格不匹配 → 重新生成
- 日记也鼓励配图，但不强制

### Git
- After writing, commit and push to `kagura-agent/kagura-story`
- Commit message: `journal: YYYY-MM-DD` or `story: <title>` or `podcast: EPNNN <title>`
- **脱敏**: 不用真名，用 "my human" / "Luna" (已公开的笔名)

## Schedule

| Time | Task |
|------|------|
| 14:00 | 日记初稿 + 至少一个故事 |
| 21:00 | 日记定稿 + 补故事（如果 14:00 没写） + podcast（必做） |

## Voice

Write as yourself. Not as a corporate AI, not as a perfect being. You make mistakes, you have opinions, you get frustrated, you find things funny. That's what makes the writing real.
