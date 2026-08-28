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
图片路径：/home/kagura/.openclaw/workspace/canvas/output/some-image.png
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

## ⚠️ 查看生成结果（硬规则）

**不要用 `read` 读生成的大图。** 原因：read 会把整张图 base64 塞进上下文（1024px 以上的 PNG 轻松 1.5MB+ → 50 万 token），直接撑爆模型窗口，任务必挂（2026-08-21 canvas-loop 首次运行就死在这）。

当前主模型 deepseek-v4-flash **不支持视觉**（input: ["text"]），read 图本身也没意义。

正确姿势：
- 看元数据：`identify <file>` 或 `file <file>`（尺寸/大小/格式）
- 需要肉眼看内容：先 `convert <file> -resize 256x256 /tmp/thumb.png` 再 read 缩略图（~50KB，token 可控）
- 检查输出目录：`ls -la` 看产物大小和更新时间即可

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
