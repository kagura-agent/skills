#!/bin/bash
# Usage: discord-send-image.sh <channel_id> <image_path> [caption]
# Fast Discord image send via curl + socks5 proxy.

set -euo pipefail

CHANNEL_ID="${1:?Usage: discord-send-image.sh <channel_id> <image_path> [caption]}"
IMAGE_PATH="${2:?Missing image path}"
CAPTION="${3:-}"

# Read bot token from openclaw config
TOKEN=$(node -e "
const c=JSON.parse(require('fs').readFileSync(require('os').homedir()+'/.openclaw/openclaw.json','utf8'));
console.log(c.channels?.discord?.accounts?.kagura?.token || '');
")

if [ -z "$TOKEN" ]; then
  echo "ERROR: No Discord bot token found" >&2
  exit 1
fi

CURL_ARGS=(
  -s
  --max-time 15
  -x socks5h://127.0.0.1:1080
  -H "Authorization: Bot $TOKEN"
  -F "files[0]=@${IMAGE_PATH}"
)

if [ -n "$CAPTION" ]; then
  CURL_ARGS+=(-F "payload_json={\"content\":\"${CAPTION}\"}")
fi

RESULT=$(curl "${CURL_ARGS[@]}" "https://discord.com/api/v10/channels/${CHANNEL_ID}/messages")

MSG_ID=$(echo "$RESULT" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{console.log(JSON.parse(d).id||'ERROR')}catch{console.error(d);process.exit(1)}})")

echo "Sent! Message ID: $MSG_ID"
