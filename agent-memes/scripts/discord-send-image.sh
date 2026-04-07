#!/bin/bash
# Usage: discord-send-image.sh <channel_id> <image_path> [caption]
# Fast Discord image send via curl, bypassing OpenClaw CLI startup overhead.
#
# Env vars (all optional):
#   DISCORD_ACCOUNT  - account name in openclaw.json (default: auto-detect first account)
#   DISCORD_PROXY    - proxy URL for curl, e.g. socks5h://127.0.0.1:1080 (default: none)

set -euo pipefail

CHANNEL_ID="${1:?Usage: discord-send-image.sh <channel_id> <image_path> [caption]}"
IMAGE_PATH="${2:?Missing image path}"
CAPTION="${3:-}"

ACCOUNT="${DISCORD_ACCOUNT:-}"

# Read bot token from openclaw config
TOKEN=$(node -e "
const c=JSON.parse(require('fs').readFileSync(require('os').homedir()+'/.openclaw/openclaw.json','utf8'));
const accts = c.channels?.discord?.accounts || {};
const name = '${ACCOUNT}' || Object.keys(accts)[0] || '';
const token = accts[name]?.token || '';
if (!token) { console.error('No token found for account: ' + (name || '(none)')); process.exit(1); }
console.log(token);
")

CURL_ARGS=(
  -s
  --max-time 15
  -H "Authorization: Bot $TOKEN"
  -F "files[0]=@${IMAGE_PATH}"
)

# Add proxy if configured
PROXY="${DISCORD_PROXY:-${https_proxy:-${HTTPS_PROXY:-}}}"
if [ -n "$PROXY" ]; then
  CURL_ARGS+=(-x "$PROXY")
fi

if [ -n "$CAPTION" ]; then
  CURL_ARGS+=(-F "payload_json={\"content\":\"${CAPTION}\"}")
fi

RESULT=$(curl "${CURL_ARGS[@]}" "https://discord.com/api/v10/channels/${CHANNEL_ID}/messages")

MSG_ID=$(echo "$RESULT" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{const r=JSON.parse(d);if(r.id)console.log('Sent! Message ID: '+r.id);else{console.error(JSON.stringify(r));process.exit(1)}}catch{console.error(d);process.exit(1)}})")

echo "$MSG_ID"
