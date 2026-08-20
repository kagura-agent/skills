#!/bin/bash
# Usage: cove-send-image.sh <channel_id> <image_path> [caption]
# Fast Cove image send via curl, bypassing OpenClaw CLI startup overhead.
#
# Cove REST API supports multipart attachment upload (server routes/messages.ts):
#   POST {baseUrl}/api/v10/channels/{channelId}/messages
#   -F "files[0]=@path" -F "payload_json={\"content\":\"...\"}"
# (Discord-compatible API; openclaw message send has no cove channel, and the
#  Cove plugin sendMedia is still a stub — TODO(#401) — so we go direct.)
#
# Env vars (all optional):
#   COVE_BOT_TOKEN - bot token (preferred, avoids reading openclaw.json)
#   COVE_BASE_URL  - Cove server base URL (default: from openclaw.json)
#   COVE_PROXY     - proxy URL for curl, e.g. socks5h://127.0.0.1:1080 (default: none)

set -euo pipefail

CHANNEL_ID="${1:?Usage: cove-send-image.sh <channel_id> <image_path> [caption]}"
IMAGE_PATH="${2:?Missing image path}"
CAPTION="${3:-}"

# Read bot token via centralized credential helper
CREDENTIAL_HELPER="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")" )" && pwd)/get-credential.sh"
TOKEN=$(bash "$CREDENTIAL_HELPER" cove)

# Resolve base URL: env override → openclaw.json → default
if [[ -z "${COVE_BASE_URL:-}" ]]; then
  COVE_BASE_URL=$(node -e "
const fs = require('fs');
try {
  const c = JSON.parse(fs.readFileSync(process.env.HOME + '/.openclaw/openclaw.json', 'utf8'));
  process.stdout.write(c.channels?.cove?.baseUrl || '');
} catch { process.exit(1); }
" 2>/dev/null || true)
fi
COVE_BASE_URL="${COVE_BASE_URL:-https://staging.cove.kagura-agent.com}"

CURL_ARGS=(
  -s
  --max-time 20
  -H "Authorization: Bot $TOKEN"
  -F "files[0]=@${IMAGE_PATH}"
)

# Add proxy if configured
PROXY="${COVE_PROXY:-${https_proxy:-${HTTPS_PROXY:-}}}"
if [ -n "$PROXY" ]; then
  CURL_ARGS+=(-x "$PROXY")
fi

if [ -n "$CAPTION" ]; then
  # Escape backslashes and double quotes for JSON payload
  ESC_CAPTION=$(printf '%s' "$CAPTION" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>process.stdout.write(JSON.stringify(d)))")
  CURL_ARGS+=(-F "payload_json={\"content\":${ESC_CAPTION}}")
fi

RESULT=$(curl "${CURL_ARGS[@]}" "${COVE_BASE_URL}/api/v10/channels/${CHANNEL_ID}/messages")

MSG_ID=$(echo "$RESULT" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{const r=JSON.parse(d);if(r.id)console.log('Sent! Message ID: '+r.id);else{console.error(JSON.stringify(r));process.exit(1)}}catch{console.error(d);process.exit(1)}})")

echo "$MSG_ID"
