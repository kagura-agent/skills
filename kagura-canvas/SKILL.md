---
name: kagura-canvas
version: 0.1.0
description: Image generation factory via #kagura-canvas channel. Use when you need to generate images — story illustrations, profile pictures, concept art, or any visual content. Delegates to the canvas channel which handles model selection, generation, and quality control. Triggers on: draw, paint, generate image, 画图, 生图, canvas, illustration, 配图.
---

# kagura-canvas

Request images from the #kagura-canvas channel. Canvas is a channel-as-service — you send a natural language request, it generates the image and returns the path.

## How to Request an Image

```python
# In any session, use sessions_send:
sessions_send(
  sessionKey="agent:kagura:discord:channel:1497073534004891648",
  message="你的画图描述，自然语言即可",
  timeoutSeconds=180
)
```

The reply will contain the image path, like:
```
图片路径：/home/kagura/.openclaw/workspace/some-image.png
```

Parse the path from the reply and use it however you need (embed in story, send to channel, etc).

## Writing Good Requests

**从内容出发，不要默认画自己。** 描述你要的场景、情绪、意象。

好的请求：
- "画一只橘猫在窗台上晒太阳，午后暖光"
- "一片空荡荡的天花板，白色，略带孤独感"
- "樱花花瓣在风中飘落，淡蓝色天空背景"
- "一台笔记本电脑屏幕上满是等待中的 PR，暗色调"

不好的请求：
- "画一张好看的图"（太模糊）
- "画我"（除非故事确实需要）

**可以指定风格**（可选）：
- "温暖梦幻风" → canvas 会选合适的模型
- "写实风格" / "动漫风" / "线稿风"
- 不指定也行，canvas 会根据描述自己判断

## 展示结果到 Discord（可选）

如果你想让生成的图在 Discord channel 里可见：

```bash
# 文字展示
openclaw message send --channel discord --account kagura \
  --target "channel:<目标channel_id>" \
  --message "🎨 配图：<描述>"
```

注意：media 上传目前有 Content-Type 问题待修，先发文字+路径。

## 超时与性能

- 本地 GPU (Flux): ~68s/张
- 云端 (Gemini): ~10s/张
- `timeoutSeconds=180` 足够应对大部分情况
- Canvas 会自动选择可用的后端

## 前提配置

需要 `tools.sessions.visibility: "all"`（已配置）。如果遇到 "visibility is restricted" 错误，检查 `~/.openclaw/openclaw.json` 的 `tools.sessions.visibility` 设置。

## 谁在用

- **kagura-storyteller**: 故事配图
- 任何需要图片的 channel 或 cron 都可以调用
