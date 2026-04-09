---
name: discord-ops
version: 1.0.0
description: Manage Discord server multi-channel collaboration: channel/thread lifecycle, pin board read/write, cron routing, status sync. Triggers on: Discord channel, thread, pin management, cron routing.
---

# discord-ops — Discord Channel 协作管理

## Description
管理 Discord server 的多 channel 协作架构：channel/thread 生命周期、pin 看板读写、cron 路由、状态同步。当需要创建/管理 Discord channel、thread、pin，或者配置 cron 到不同 channel 时触发此 skill。

## Triggers
- 创建 Discord channel / thread
- 管理 Discord pin（读/写/更新 backlog）
- 配置 cron 路由到不同 channel
- 同步 TODO.md 到 pin
- Discord server 管理

## Context
- 架构设计文档: `wiki/projects/discord-ops.md`
- Pin IDs: `TOOLS.md` → Discord Pin Message IDs 章节
- Cron 配置: `~/.openclaw/cron/jobs.json`
- OpenClaw Discord 配置: `~/.openclaw/openclaw.json` → channels.discord

## Channel Structure
```
#kagura-dm (1491602968741413039) — 总控室
#work      (1491636222853124176) — 打工
#study     (1491644155451932934) — 学习
#community (1491644145826005164) — 社区运营
Guild: 1490989630382931980
```

## Operations

### 1. 创建 Thread
```bash
export https_proxy="http://127.0.0.1:1083"
BOT_TOKEN="从 openclaw.json 读取"
curl -s -X POST -H "Authorization: Bot $BOT_TOKEN" -H "Content-Type: application/json" \
  "https://discord.com/api/v10/channels/{CHANNEL_ID}/threads" \
  -d '{"name": "🔨 标题", "type": 11, "auto_archive_duration": 1440}'
```

### 2. 发消息到 Thread/Channel
```bash
curl -s -X POST -H "Authorization: Bot $BOT_TOKEN" -H "Content-Type: application/json" \
  "https://discord.com/api/v10/channels/{CHANNEL_OR_THREAD_ID}/messages" \
  -d '{"content": "消息内容"}'
```

### 3. 读 Pin 内容
```bash
curl -s -H "Authorization: Bot $BOT_TOKEN" \
  "https://discord.com/api/v10/channels/{CHANNEL_ID}/pins"
```

### 4. 编辑 Pin 消息（更新 Backlog）
```bash
curl -s -X PATCH -H "Authorization: Bot $BOT_TOKEN" -H "Content-Type: application/json" \
  "https://discord.com/api/v10/channels/{CHANNEL_ID}/messages/{MESSAGE_ID}" \
  -d '{"content": "更新后的内容"}'
```

### 5. 同步 TODO.md → Pin
读 TODO.md → 格式化为 Discord 消息 → PATCH 更新 pin message

### 6. 重命名 Thread
```bash
curl -s -X PATCH -H "Authorization: Bot $BOT_TOKEN" -H "Content-Type: application/json" \
  "https://discord.com/api/v10/channels/{THREAD_ID}" \
  -d '{"name": "🔨 新标题"}'
```

### 7. 添加新 Channel 到 OpenClaw 监听
编辑 `~/.openclaw/openclaw.json` → `channels.discord.accounts.kagura.guilds.{GUILD_ID}.channels` 添加 channel ID

## Rules
- Bot Token 从 openclaw.json 读取，不硬编码
- 所有 Discord API 调用需要 `https_proxy`
- Discord 消息上限 2000 字符，超长需截断
- Pin 上限 50 条/channel
- Thread `auto_archive_duration`: 1440 (24h) 或 4320 (3天)
- 创建新 channel 后必须加到 OpenClaw 监听配置
