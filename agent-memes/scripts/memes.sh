#!/usr/bin/env bash
# memes - Agent meme library manager
# Usage: memes <command> [args]

set -euo pipefail

# Default meme library path (override with MEMES_DIR)
MEMES_DIR="${MEMES_DIR:-$HOME/.openclaw/workspace/memes}"

usage() {
  cat <<EOF
Usage: memes <command> [args]

Commands:
  pick <category>   Randomly pick a meme from a category, print its path
  categories        List all categories with counts

Environment:
  MEMES_DIR         Path to meme library (default: ~/.openclaw/workspace/memes)
EOF
  exit 1
}

cmd_categories() {
  if [[ ! -d "$MEMES_DIR" ]]; then
    echo "Error: Meme library not found at $MEMES_DIR" >&2
    exit 1
  fi
  for dir in "$MEMES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    name=$(basename "$dir")
    [[ "$name" == .* ]] && continue
    count=$(find "$dir" -maxdepth 1 -type f \( -name '*.gif' -o -name '*.jpg' -o -name '*.png' -o -name '*.webp' \) 2>/dev/null | wc -l)
    printf "%-20s %d\n" "$name" "$count"
  done | sort
}

cmd_pick() {
  local category="${1:-}"
  if [[ -z "$category" ]]; then
    echo "Usage: memes pick <category>" >&2
    exit 1
  fi
  local dir="$MEMES_DIR/$category"
  if [[ ! -d "$dir" ]]; then
    echo "Error: Category '$category' not found. Run 'memes categories' to see available." >&2
    exit 1
  fi
  local files=()
  while IFS= read -r f; do
    files+=("$f")
  done < <(find "$dir" -maxdepth 1 -type f \( -name '*.gif' -o -name '*.jpg' -o -name '*.png' -o -name '*.webp' \) 2>/dev/null)
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "Error: No memes in '$category'" >&2
    exit 1
  fi
  local idx=$((RANDOM % ${#files[@]}))
  echo "${files[$idx]}"
}

# Main
[[ $# -lt 1 ]] && usage
case "$1" in
  pick)       shift; cmd_pick "$@" ;;
  categories) cmd_categories ;;
  -h|--help)  usage ;;
  *)          echo "Unknown command: $1" >&2; usage ;;
esac
