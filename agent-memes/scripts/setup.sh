#!/usr/bin/env bash
# Auto-setup: clone or update meme repo into workspace
set -e

MEME_DIR="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}/memes"

if [ -d "$MEME_DIR/.git" ]; then
  echo "📦 Updating memes..."
  cd "$MEME_DIR" && git pull --ff-only
else
  echo "📦 Cloning meme repo..."
  git clone https://github.com/kagura-agent/memes "$MEME_DIR"
fi

echo "✅ Memes ready at $MEME_DIR ($(find "$MEME_DIR" -type f \( -name '*.gif' -o -name '*.jpg' -o -name '*.png' \) | wc -l) files)"
