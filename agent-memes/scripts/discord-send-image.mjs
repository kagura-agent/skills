#!/usr/bin/env node
// Usage: node scripts/discord-send-image.mjs <channel_id> <image_path> [caption]
// Fast Discord image send — bypasses OpenClaw CLI startup overhead.

import { readFileSync } from 'fs';
import { resolve, basename } from 'path';
import { homedir } from 'os';

const [channelId, imagePath, caption] = process.argv.slice(2);
if (!channelId || !imagePath) {
  console.error('Usage: node discord-send-image.mjs <channel_id> <image_path> [caption]');
  process.exit(1);
}

// --- credentials ---
const configPath = resolve(homedir(), '.openclaw/openclaw.json');
const config = JSON.parse(readFileSync(configPath, 'utf8'));
const token = config.channels?.discord?.accounts?.kagura?.token;
if (!token) {
  console.error('Missing token in ~/.openclaw/openclaw.json (channels.discord.accounts.kagura.token)');
  process.exit(1);
}

// --- build multipart form ---
const fileData = readFileSync(resolve(imagePath));
const fileName = basename(imagePath);
const boundary = '----OpenClawBoundary' + Date.now();

const parts = [];

// file attachment
parts.push(
  `--${boundary}\r\n` +
  `Content-Disposition: form-data; name="files[0]"; filename="${fileName}"\r\n` +
  `Content-Type: application/octet-stream\r\n\r\n`
);
parts.push(fileData);
parts.push('\r\n');

// optional caption as payload_json
if (caption) {
  const payload = JSON.stringify({ content: caption });
  parts.push(
    `--${boundary}\r\n` +
    `Content-Disposition: form-data; name="payload_json"\r\n` +
    `Content-Type: application/json\r\n\r\n` +
    payload + '\r\n'
  );
}

parts.push(`--${boundary}--\r\n`);

// concat into single buffer
const body = Buffer.concat(parts.map(p => typeof p === 'string' ? Buffer.from(p) : p));

// --- send ---
const res = await fetch(`https://discord.com/api/v10/channels/${channelId}/messages`, {
  method: 'POST',
  headers: {
    'Authorization': `Bot ${token}`,
    'Content-Type': `multipart/form-data; boundary=${boundary}`,
  },
  body,
});

if (!res.ok) {
  const text = await res.text();
  console.error(`Discord API error ${res.status}: ${text}`);
  process.exit(1);
}

const data = await res.json();
console.log(`Sent! Message ID: ${data.id}`);
