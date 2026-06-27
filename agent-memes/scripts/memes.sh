#!/usr/bin/env bash
# memes - Agent meme library manager with multi-platform send
set -euo pipefail

MEMES_DIR="${MEMES_DIR:-$HOME/.openclaw/workspace/memes}"
# Load config file if present (sets defaults for MEMES_DEFAULT_*, OPENCLAW_CHANNEL, etc.)
MEMES_CONFIG="${MEMES_CONFIG:-$HOME/.config/memes/config}"
[[ -f "$MEMES_CONFIG" ]] && source "$MEMES_CONFIG"
# Also check legacy location
[[ -f "$HOME/.memesrc" ]] && source "$HOME/.memesrc"
# Auto-detect channel + target from OpenClaw runtime context file
# Format: "platform:target" e.g. "telegram:12345" or "discord:98765" or just "telegram"
OPENCLAW_CHANNEL_FILE="${OPENCLAW_CHANNEL_FILE:-/tmp/openclaw-current-channel}"
if [[ -z "${OPENCLAW_CHANNEL:-}" && -f "$OPENCLAW_CHANNEL_FILE" ]]; then
  # Only use file if it's less than 5 minutes old (300 seconds)
  _file_age=$(( $(date +%s) - $(stat -c %Y "$OPENCLAW_CHANNEL_FILE" 2>/dev/null || echo 0) ))
  if [[ $_file_age -lt 300 ]]; then
    _ctx=$(cat "$OPENCLAW_CHANNEL_FILE")
    if [[ "$_ctx" == *:* ]]; then
      OPENCLAW_CHANNEL="${_ctx%%:*}"
      MEMES_CURRENT_TARGET="${_ctx#*:}"
    else
      OPENCLAW_CHANNEL="$_ctx"
    fi
  fi
fi
# Auto-detect scripts dir: same directory as this script, or override with MEMES_SCRIPTS
SCRIPTS_DIR="${MEMES_SCRIPTS:-$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/.." 2>/dev/null && pwd)/scripts}"
[[ ! -d "$SCRIPTS_DIR" ]] && SCRIPTS_DIR="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"

usage() {
  cat <<EOF
Usage: memes <command> [args]

Commands:
  pick <category>         Randomly pick a meme, print its path
  list <category>         List all memes in a category
  random                  Pick from any category at random
  send <category> [caption] [--to target] [--channel platform] [--account name]
  categories              List all categories with counts
  stats                   Show usage stats from tracker (frequency, last-used)
  search <query>          Search memes by tags (fuzzy cross-category match)
  backfill-files          Fill missing 'file' field in old tracker entries
  normalize               Fix malformed tracker entries (missing fields, old date format)
  expire-legacy           Mark unresolvable 'legacy' file entries as permanently expired
  audit [min_files]       Check category health and tag coverage (default min: 3)
  health                  Combined health check: audit + tracker integrity + oversized files
  quality                 Check for duplicate filenames, generic names, near-dupes, missing tags/styles

Platforms with fast send: discord, feishu, telegram
Other platforms fall back to: openclaw message send

Examples:
  memes send happy "好开心！" --to <channel_id>         # → Discord
  memes send facepalm --to channel:1491636222853124176  # → Discord #work
  memes send feishu cute-animals "看！" --to user:xxx   # → Feishu
  memes send telegram wow --to 12345678                 # → Telegram
EOF
  exit 1
}

cmd_categories() {
  [[ ! -d "$MEMES_DIR" ]] && { echo "Error: Meme library not found at $MEMES_DIR" >&2; exit 1; }
  for dir in "$MEMES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    name=$(basename "$dir"); [[ "$name" == .* ]] && continue
    count=$(find "$dir" -maxdepth 1 -type f \( -name '*.gif' -o -name '*.jpg' -o -name '*.png' -o -name '*.webp' \) 2>/dev/null | wc -l)
    printf "%-20s %d\n" "$name" "$count"
  done | sort
}

# Resolve alias/Chinese name to canonical category folder name
_resolve_category() {
  local cat="${1:-}"
  declare -A ALIASES=(
    [哇]=wow [惊讶]=wow [surprised]=wow
    [开心]=happy [高兴]=happy [庆祝]=happy [celebrate]=happy
    [无语]=facepalm [晕]=facepalm [服了]=facepalm
    [加油]=encourage [鼓励]=encourage
    [可爱]=cute-animals [萌]=cute-animals [猫]=cute-animals
    [难过]=sad [伤心]=sad
    [累]=tired [困]=tired
    [爱]=love [喜欢]=love
    [谢谢]=thanks [感谢]=thanks
    [想]=thinking [思考]=thinking [嗯]=thinking
    [慌]=panic [急]=panic
    [早]=greeting-morning [早安]=greeting-morning
    [晚安]=greeting-night [晚]=greeting-night
    [你好]=greeting-hello [hi]=greeting-hello [hello]=greeting-hello
    [再见]=greeting-bye [拜]=greeting-bye [bye]=greeting-bye
    [赞]=approve [好]=approve
    [debug]=debug-mood [bug]=debug-mood
    [迷惑]=confused [懵]=confused
    [摊手]=shrug [无奈]=shrug [没办法]=shrug [随便]=shrug
    [干活]=working [忙]=working [在搞]=working [coding]=working
    [失望]=disappointed [唉]=disappointed
    [得意]=smug [嘚瑟]=smug [heh]=smug
    [吃瓜]=popcorn [看戏]=popcorn
    [等]=waiting [等等]=waiting [等待]=waiting
    [牛]=nailed-it [完美]=nailed-it [nice]=nailed-it
    [无语子]=bruh [真的假的]=bruh [离谱]=bruh
  )
  echo "${ALIASES[$cat]:-$cat}"
}

cmd_pick() {
  local category="${1:-}"
  [[ -z "$category" ]] && { echo "Usage: memes pick <category>" >&2; exit 1; }
  category=$(_resolve_category "$category")
  local dir="$MEMES_DIR/$category"
  [[ ! -d "$dir" ]] && { echo "Error: Category '$category' not found. Run 'memes categories' for list." >&2; exit 1; }
  local files=()
  while IFS= read -r f; do files+=("$f"); done < <(find "$dir" -maxdepth 1 -type f \( -name '*.gif' -o -name '*.jpg' -o -name '*.png' -o -name '*.webp' \) 2>/dev/null)
  [[ ${#files[@]} -eq 0 ]] && { echo "Error: No memes in '$category'" >&2; exit 1; }

  # Exclude specific file (used by auto-retry to avoid picking the same failed file)
  if [[ -n "${MEMES_EXCLUDE_FILE:-}" ]] && [[ ${#files[@]} -gt 1 ]]; then
    local excl_filtered=()
    for f in "${files[@]}"; do
      [[ "$(basename "$f")" != "$MEMES_EXCLUDE_FILE" ]] && excl_filtered+=("$f")
    done
    [[ ${#excl_filtered[@]} -gt 0 ]] && files=("${excl_filtered[@]}")
  fi

  # Per-file recency avoidance: skip files picked recently in this category
  local tracker_file="$MEMES_DIR/meme-tracker.json"
  local file_recency=${MEMES_FILE_RECENCY_WINDOW:-5}
  if command -v jq &>/dev/null && [[ -f "$tracker_file" ]] && [[ ${#files[@]} -gt 1 ]]; then
    local -A recent_files=()
    while read -r fname; do
      [[ -n "$fname" ]] && recent_files["$fname"]=1
    done < <(jq -r --arg cat "$category" --argjson n "$file_recency" '
      [.history[] | select(.category == $cat and .file != null) | .file]
      | .[-$n:][]' "$tracker_file" 2>/dev/null)
    if [[ ${#recent_files[@]} -gt 0 ]]; then
      local filtered=()
      for f in "${files[@]}"; do
        local basename_f; basename_f=$(basename "$f")
        [[ -z "${recent_files[$basename_f]:-}" ]] && filtered+=("$f")
      done
      # Only use filtered list if it's non-empty (avoid deadlock when all files recently used)
      [[ ${#filtered[@]} -gt 0 ]] && files=("${filtered[@]}")
    fi
  fi

  local picked="${files[$((RANDOM % ${#files[@]}))]}"
  # Detect git LFS pointer (not real image)
  if [[ $(stat -c%s "$picked" 2>/dev/null || stat -f%z "$picked" 2>/dev/null) -lt 1024 ]] && grep -q 'oid sha256' "$picked" 2>/dev/null; then
    echo "Error: '$picked' is a git LFS pointer, not a real image." >&2
    echo "Run: cd \"$MEMES_DIR\" && git lfs pull" >&2
    exit 1
  fi

  # Diversity nudge: hint when category is overused in the last 7 days
  if command -v jq &>/dev/null && [[ -f "$tracker_file" ]]; then
    local nudge_threshold=${MEMES_NUDGE_THRESHOLD:-4}
    local cat_7d_count
    cat_7d_count=$(jq -r --arg cat "$category" --arg since "$(date -d '7 days ago' +%Y-%m-%dT%H:%M 2>/dev/null || date -v-7d +%Y-%m-%dT%H:%M 2>/dev/null)" '
      [.history[] | select(.category == $cat and .time >= $since)] | length' "$tracker_file" 2>/dev/null || echo 0)
    if [[ "$cat_7d_count" -ge "$nudge_threshold" ]]; then
      # Find categories unused in 7d as alternatives
      local dormant
      dormant=$(jq -r --arg since "$(date -d '7 days ago' +%Y-%m-%dT%H:%M 2>/dev/null || date -v-7d +%Y-%m-%dT%H:%M 2>/dev/null)" '
        [.history[] | select(.time >= $since) | .category] | unique as $used |
        ["approve","bruh","confused","cute-animals","debug-mood","disappointed","encourage","facepalm","greeting-bye","greeting-hello","greeting-morning","greeting-night","happy","love","nailed-it","panic","popcorn","sad","shrug","smug","thanks","thinking","tired","waiting","working","wow"] |
        [.[] | select(. as $c | $used | index($c) | not)] | .[0:3] | join(", ")' "$tracker_file" 2>/dev/null)
      if [[ -n "$dormant" ]]; then
        echo "💡 $category used ${cat_7d_count}x in 7d. Dormant alternatives: $dormant" >&2
      fi
    fi
  fi

  echo "$picked"
}

cmd_list() {
  local category="${1:-}"
  [[ -z "$category" ]] && { echo "Usage: memes list <category>" >&2; exit 1; }
  local dir="$MEMES_DIR/$category"
  [[ ! -d "$dir" ]] && { echo "Error: Category '$category' not found." >&2; exit 1; }
  find "$dir" -maxdepth 1 -type f \( -name '*.gif' -o -name '*.jpg' -o -name '*.png' -o -name '*.webp' \) 2>/dev/null | sort
}

cmd_random() {
  local tags_file="$MEMES_DIR/tags.json"
  local tracker_file="$MEMES_DIR/meme-tracker.json"
  local recency_window=${MEMES_RECENCY_WINDOW:-3}

  # Build recency skip list from last N tracker entries
  local -A recent_cats=()
  if command -v jq &>/dev/null && [[ -f "$tracker_file" ]]; then
    while read -r cat; do
      [[ -n "$cat" ]] && recent_cats["$cat"]=1
    done < <(jq -r --argjson n "$recency_window" '[.history[-$n:][].category // empty] | unique[]' "$tracker_file" 2>/dev/null)
  fi

  # Inverse-sqrt weighted random: categories with fewer files get boosted,
  # so cute-animals (30 files) doesn't dominate random picks.
  # Weight = 1000/sqrt(count), quantized to integers for bash arithmetic.
  # Recent categories (last $recency_window sends) are skipped for variety.
  if command -v jq &>/dev/null && [[ -f "$tags_file" ]]; then
    local -a cats=() weights=()
    local total_weight=0
    while IFS='=' read -r name count; do
      [[ -z "$name" || -z "$count" ]] && continue
      # Skip recently used categories
      [[ -n "${recent_cats[$name]:-}" ]] && continue
      cats+=("$name")
      # inverse-sqrt: 1000/sqrt(count), min 1
      local w; w=$(awk "BEGIN{v=int(1000/sqrt($count)); print (v<1?1:v)}")
      weights+=("$w")
      total_weight=$((total_weight + w))
    done < <(jq -r '._meta.categoryCounts // {} | to_entries[] | "\(.key)=\(.value)"' "$tags_file")
    if [[ ${#cats[@]} -gt 0 && $total_weight -gt 0 ]]; then
      local roll=$((RANDOM % total_weight))
      local cumulative=0
      for i in "${!cats[@]}"; do
        cumulative=$((cumulative + weights[i]))
        if [[ $roll -lt $cumulative ]]; then
          cmd_pick "${cats[$i]}"
          return
        fi
      done
      # Fallback (shouldn't reach here)
      cmd_pick "${cats[-1]}"
      return
    fi
  fi
  # Fallback: uniform random (no jq or no tags.json)
  local cats=()
  for dir in "$MEMES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local name=$(basename "$dir"); [[ "$name" == .* ]] && continue
    cats+=("$name")
  done
  [[ ${#cats[@]} -eq 0 ]] && { echo "Error: No categories found" >&2; exit 1; }
  local cat="${cats[$((RANDOM % ${#cats[@]}))]}"
  cmd_pick "$cat"
}

cmd_stats() {
  local tracker_file="$MEMES_DIR/meme-tracker.json"
  if ! command -v jq &>/dev/null; then
    echo "Error: jq required for stats" >&2; exit 1
  fi
  if [[ ! -f "$tracker_file" ]]; then
    echo "Error: No tracker file at $tracker_file" >&2; exit 1
  fi

  local total; total=$(jq '[.history[] | select(.result != "failed")] | length' "$tracker_file")
  local failed; failed=$(jq '[.history[] | select(.result == "failed")] | length' "$tracker_file")
  local first_date; first_date=$(jq -r '.history[0].time // "unknown"' "$tracker_file" | cut -c1-10)
  local last_date; last_date=$(jq -r '.history[-1].time // "unknown"' "$tracker_file" | cut -c1-10)

  echo "=== Meme Stats ==="
  echo "Total sends: $total${failed:+ ($failed failed)}  |  Period: $first_date → $last_date"
  echo ""

  # Category frequency + last-used
  echo "Category               Count  Last Used"
  echo "─────────────────────  ─────  ──────────"
  jq -r '
    [.history[] | {cat: .category, ts: (.time // "")}]
    | group_by(.cat)
    | map({cat: .[0].cat, count: length, last: (map(.ts) | sort | last | .[0:10])})
    | sort_by(-.count)
    | .[] | "\(.cat)\t\(.count)\t\(.last)"
  ' "$tracker_file" | while IFS=$'\t' read -r cat count last; do
    printf "%-23s %5s  %s\n" "$cat" "$count" "$last"
  done

  echo ""

  # Top 3 most used
  echo "🔥 Most used:"
  jq -r '
    [.history[].category] | group_by(.) | map({cat: .[0], n: length})
    | sort_by(-.n) | .[0:3][] | "   \(.cat) (\(.n))"
  ' "$tracker_file"

  # Bottom 3 least used
  echo "❄️  Least used:"
  jq -r '
    [.history[].category] | group_by(.) | map({cat: .[0], n: length})
    | sort_by(.n) | .[0:3][] | "   \(.cat) (\(.n))"
  ' "$tracker_file"

  # Categories in library but never sent
  echo ""
  local -a lib_cats=()
  for dir in "$MEMES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local name; name=$(basename "$dir"); [[ "$name" == .* ]] && continue
    lib_cats+=("$name")
  done
  local used_cats; used_cats=$(jq -r '[.history[].category] | unique | .[]' "$tracker_file")
  local missing=0
  for cat in "${lib_cats[@]}"; do
    if ! echo "$used_cats" | grep -qx "$cat"; then
      [[ $missing -eq 0 ]] && echo "⚠️  In library but never sent:"
      echo "   $cat"
      missing=$((missing + 1))
    fi
  done
  [[ $missing -eq 0 ]] && echo "✅ All library categories have been used"

  # Style diversity per category (reads _styles from tags.json)
  local tags_file="$MEMES_DIR/tags.json"
  if [[ -f "$tags_file" ]] && jq -e '._styles' "$tags_file" &>/dev/null; then
    echo ""
    echo "🎨 Style Diversity"
    echo "Category               anime  animal  cartoon  live  meme   Dominant"
    echo "─────────────────────  ─────  ──────  ───────  ────  ─────  ────────────"
    local flagged=0
    jq -r '
      ._styles as $s |
      [$s | to_entries[] | select(.key | contains("/")) | {cat: (.key | split("/")[0]), style: .value}]
      | group_by(.cat)
      | map({
          cat: .[0].cat,
          total: length,
          anime:    [.[] | select(.style=="anime")] | length,
          animal:   [.[] | select(.style=="animal")] | length,
          cartoon:  [.[] | select(.style=="cartoon")] | length,
          live:     [.[] | select(.style=="live-action")] | length,
          meme:     [.[] | select(.style=="meme")] | length
        })
      | map(. + {
          top_style: ([ {s:"anime",n:.anime}, {s:"animal",n:.animal}, {s:"cartoon",n:.cartoon}, {s:"live-action",n:.live}, {s:"meme",n:.meme} ] | sort_by(-.n) | .[0]),
          pct: (([ .anime, .animal, .cartoon, .live, .meme ] | max) * 100 / .total | floor)
        })
      | sort_by(.cat)
      | .[] | "\(.cat)\t\(.anime)\t\(.animal)\t\(.cartoon)\t\(.live)\t\(.meme)\t\(.pct | floor)% \(.top_style.s)\(if .pct > 70 and (.cat | test("^cute-animals$|^animal") | not) then " ⚠️" else "" end)"
    ' "$tags_file" | while IFS=$'\t' read -r cat anime animal cartoon live meme dominant; do
      printf "%-23s %5s  %6s  %7s  %4s  %5s  %s\n" "$cat" "$anime" "$animal" "$cartoon" "$live" "$meme" "$dominant"
      if [[ "$dominant" == *"⚠️"* ]]; then
        flagged=$((flagged + 1))
      fi
    done
    echo ""
    # Count flagged categories
    local flag_count
    flag_count=$(jq '[
      ._styles as $s |
      [$s | to_entries[] | select(.key | contains("/")) | {cat: (.key | split("/")[0]), style: .value}]
      | group_by(.cat)
      | .[] | {cat: .[0].cat, total: length, max: ([group_by(.style) | .[] | length] | max)}
      | select((.max * 100 / .total) > 70)
      | select(.cat | test("^cute-animals$|^animal") | not)
    ] | length' "$tags_file")
    if [[ "$flag_count" -gt 0 ]]; then
      echo "⚠️  $flag_count categories have >70% single-style dominance"
    else
      echo "✅ All categories have good style diversity"
    fi
  fi
}

_track_send() {
  local category="$1" file="$2" channel="$3" caption="$4" result="${5:-success}"
  local tracker_file="$MEMES_DIR/meme-tracker.json"
  command -v jq &>/dev/null || return 0
  local ts; ts=$(date -Iseconds)
  local basename_f; basename_f=$(basename "$file")
  local entry; entry=$(jq -nc \
    --arg ts "$ts" \
    --arg cat "$category" \
    --arg file "$basename_f" \
    --arg ch "$channel" \
    --arg cap "$caption" \
    --arg res "$result" \
    '{time: $ts, action: "send", category: $cat, file: $file, channel: $ch, caption: $cap, result: $res, method: "memes send"}')
  if [[ -f "$tracker_file" ]]; then
    local tmp; tmp=$(mktemp)
    jq --argjson e "$entry" --arg ts "$ts" '.history += [$e] | .totalSent = ([.history[] | select(.result == "success" or .result == "sent")] | length) | .totalFailed = ([.history[] | select(.result == "failed")] | length) | .counts = ([.history[] | select(.result == "success" or .result == "sent") | .category] | group_by(.) | map({key: .[0], value: length}) | from_entries) | .lastUpdated = $ts' "$tracker_file" > "$tmp" && mv "$tmp" "$tracker_file"
  else
    echo "$entry" | jq '{history: [.], totalSent: 1}' > "$tracker_file"
  fi
}

cmd_send() {
  local category="" caption="" to="" channel="${OPENCLAW_CHANNEL:-discord}" account=""
  # Detect platform as first arg (overrides env default)
  [[ "${1:-}" =~ ^(discord|feishu|telegram|whatsapp|slack|line|qq|wechat)$ ]] && { channel="$1"; shift; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --category|-c)  category="$2"; shift 2 ;;
      --caption|-m)   caption="$2"; shift 2 ;;
      --to|-t)        to="$2"; shift 2 ;;
      --channel)      channel="$2"; shift 2 ;;
      --account|-a)   account="$2"; shift 2 ;;
      *)              if [[ -z "$category" ]]; then category="$1"; else caption="${caption:+$caption }$1"; fi; shift ;;
    esac
  done
  [[ -z "$category" ]] && { echo "Usage: memes send <category> [caption] [--to target] [--channel platform]" >&2; exit 1; }

  # Resolve alias so tracker records canonical category, not alias
  category=$(_resolve_category "$category")

  local meme_path; meme_path=$(cmd_pick "$category")

  # Timeout for send commands (prevents SIGKILL from parent exec timeout)
  local SEND_TIMEOUT="${MEMES_SEND_TIMEOUT:-30}"

  # Try platform-specific fast script first, fall back to openclaw CLI
  local send_rc=0
  case "$channel" in
    discord)
      local script="$SCRIPTS_DIR/discord-send-image.sh"
      local target="${to#channel:}"
      if [[ -z "$target" ]]; then
        target="${MEMES_CURRENT_TARGET:-${MEMES_DEFAULT_CHANNEL:-}}"
        [[ -z "$target" ]] && { echo "Error: --to <channel_id> required (or set MEMES_DEFAULT_CHANNEL)" >&2; exit 1; }
      fi
      if [[ -x "$script" ]]; then
        timeout "$SEND_TIMEOUT" bash "$script" "$target" "$meme_path" "$caption" || send_rc=$?
      else
        _send_openclaw "$meme_path" "$caption" "$to" "$channel" "$account" || send_rc=$?
      fi
      ;;
    feishu)
      local script="$SCRIPTS_DIR/feishu-send-image.mjs"
      local target="${to:-${MEMES_CURRENT_TARGET:-${MEMES_DEFAULT_FEISHU:-}}}"
      [[ -z "$target" ]] && { echo "Error: --to <target> required (or set MEMES_DEFAULT_FEISHU)" >&2; exit 1; }
      if [[ -f "$script" ]]; then
        timeout "$SEND_TIMEOUT" node "$script" "$target" "$meme_path" ${caption:+"$caption"} || send_rc=$?
      else
        _send_openclaw "$meme_path" "$caption" "$to" "feishu" "$account" || send_rc=$?
      fi
      ;;
    line)
      local script="$SCRIPTS_DIR/line-send-image.sh"
      local target="${to:-${MEMES_CURRENT_TARGET:-${MEMES_DEFAULT_LINE:-}}}"
      [[ -z "$target" ]] && { echo "Error: --to <user_or_group_id> required (or set MEMES_DEFAULT_LINE)" >&2; exit 1; }
      if [[ -x "$script" ]]; then
        timeout "$SEND_TIMEOUT" bash "$script" "$target" "$meme_path" "$caption" || send_rc=$?
      else
        _send_openclaw "$meme_path" "$caption" "$to" "line" "$account" || send_rc=$?
      fi
      ;;
    telegram)
      local script="$SCRIPTS_DIR/telegram-send-image.sh"
      local target="${to:-${MEMES_CURRENT_TARGET:-${MEMES_DEFAULT_TELEGRAM:-}}}"
      [[ -z "$target" ]] && { echo "Error: --to <chat_id> required (or set MEMES_DEFAULT_TELEGRAM)" >&2; exit 1; }
      if [[ -x "$script" ]]; then
        timeout "$SEND_TIMEOUT" bash "$script" "$target" "$meme_path" "$caption" || send_rc=$?
      else
        _send_openclaw "$meme_path" "$caption" "$to" "telegram" "$account" || send_rc=$?
      fi
      ;;
    *)
      local script="$SCRIPTS_DIR/${channel}-send-image.sh"
      if [[ -x "$script" ]]; then
        timeout "$SEND_TIMEOUT" bash "$script" "${to:-}" "$meme_path" "$caption" || send_rc=$?
      else
        _send_openclaw "$meme_path" "$caption" "$to" "$channel" "$account" || send_rc=$?
      fi
      ;;
  esac

  # Auto-retry with a different file on failure (once)
  if [[ $send_rc -ne 0 ]]; then
    _track_send "$category" "$meme_path" "$channel" "$caption" "failed"
    echo "[memes] send failed for $(basename "$meme_path"), retrying with another file..." >&2
    local retry_path; retry_path=$(MEMES_EXCLUDE_FILE="$(basename "$meme_path")" cmd_pick "$category" 2>/dev/null || true)
    if [[ -n "$retry_path" && "$retry_path" != "$meme_path" ]]; then
      local retry_rc=0
      case "$channel" in
        discord)
          local r_target="${to#channel:}"
          [[ -z "$r_target" ]] && r_target="${MEMES_CURRENT_TARGET:-${MEMES_DEFAULT_CHANNEL:-}}"
          timeout "$SEND_TIMEOUT" bash "$SCRIPTS_DIR/discord-send-image.sh" "$r_target" "$retry_path" "$caption" || retry_rc=$?
          ;;
        *) _send_openclaw "$retry_path" "$caption" "$to" "$channel" "$account" || retry_rc=$? ;;
      esac
      local retry_result="success"
      [[ $retry_rc -ne 0 ]] && retry_result="failed"
      _track_send "$category" "$retry_path" "$channel" "$caption" "$retry_result"
      echo "$retry_path"
      return $retry_rc
    fi
    # Retry pick failed (single-file category or same file picked), report original failure
    echo "$meme_path"
    return $send_rc
  fi

  # Track successful send
  _track_send "$category" "$meme_path" "$channel" "$caption" "success"
  echo "$meme_path"
  return 0
}

_send_openclaw() {
  local meme_path="$1" caption="$2" to="$3" channel="$4" account="$5"
  local send_timeout="${MEMES_SEND_TIMEOUT:-30}"
  local cmd="openclaw message send"
  cmd+=" --channel $channel"
  [[ -n "$account" ]] && cmd+=" --account $account"
  [[ -n "$to" ]] && cmd+=" --target \"$to\""
  cmd+=" --media \"$meme_path\""
  [[ -n "$caption" ]] && cmd+=" --message \"$caption\""
  timeout "$send_timeout" bash -c "$cmd" 2>&1
}

cmd_search() {
  local query="${1:-}"
  [[ -z "$query" ]] && { echo "Usage: memes search <query>" >&2; echo "Examples: memes search coding, memes search cute sad, memes search fire chaos" >&2; exit 1; }
  local tags_file="$MEMES_DIR/tags.json"
  if ! command -v jq &>/dev/null; then
    echo "Error: jq required for search" >&2; exit 1
  fi
  [[ ! -f "$tags_file" ]] && { echo "Error: No tags.json at $tags_file" >&2; exit 1; }

  # Split query into words, match against tags
  local -a query_words=()
  for word in $query; do
    query_words+=("$(echo "$word" | tr '[:upper:]' '[:lower:]')")
  done

  # Score each file: count how many query words match any of its tags (substring match)
  local results; results=$(jq -r --arg q "${query_words[*]}" '
    ($q | split(" ")) as $words |
    to_entries
    | map(select(.key != "_meta" and (.value | type == "array")))
    | map({
        file: .key,
        cat: (.key | split("/")[0]),
        tags: .value,
        score: ([.value[] as $tag | $words[] as $w | select($tag | test($w; "i"))] | length)
      })
    | map(select(.score > 0))
    | sort_by(-.score)
    | .[:15]
    | .[] | "\(.score)\t\(.cat)\t\(.file)\t\(.tags | join(", "))"
  ' "$tags_file" 2>/dev/null)

  if [[ -z "$results" ]]; then
    echo "No matches for: $query" >&2
    echo "Try broader terms or run 'memes categories' for available categories" >&2
    return 1
  fi

  echo "Search: $query"
  echo "Score  Category               File"
  echo "─────  ─────────────────────  ──────────────────────────"
  echo "$results" | while IFS=$'\t' read -r score cat file tags; do
    local basename_f; basename_f=$(basename "$file")
    printf "%-6s %-23s %s\n" "$score" "$cat" "$basename_f"
  done
  echo ""
  echo "Tags matched in top result:"
  echo "$results" | head -1 | while IFS=$'\t' read -r score cat file tags; do
    echo "  $tags"
  done
}

cmd_backfill_files() {
  local tracker_file="$MEMES_DIR/meme-tracker.json"
  if ! command -v jq &>/dev/null; then
    echo "Error: jq required for backfill-files" >&2; exit 1
  fi
  if [[ ! -f "$tracker_file" ]]; then
    echo "Error: No tracker file at $tracker_file" >&2; exit 1
  fi

  local missing; missing=$(jq '[.history[] | select(.file == null or .file == "")] | length' "$tracker_file")
  local total; total=$(jq '.history | length' "$tracker_file")

  if [[ "$missing" -eq 0 ]]; then
    echo "✅ All $total entries already have file field"
    return 0
  fi

  echo "Found $missing/$total entries missing file field"

  # For entries with missing file: if the category has exactly 1 file, we can infer it.
  # Otherwise mark as "legacy" (unknowable — random pick wasn't recorded).
  local tmp; tmp=$(mktemp)
  jq --arg memes_dir "$MEMES_DIR" '
    .history |= [.[] | 
      if (.file == null or .file == "") then
        .file = "legacy"
      else . end
    ]
  ' "$tracker_file" > "$tmp"

  # Try to infer single-file categories
  local inferred=0
  for dir in "$MEMES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local cat; cat=$(basename "$dir")
    [[ "$cat" == .* ]] && continue
    local files; files=$(find "$dir" -maxdepth 1 -type f \( -name '*.gif' -o -name '*.jpg' -o -name '*.png' -o -name '*.webp' \) 2>/dev/null)
    local count; count=$(echo "$files" | grep -c . 2>/dev/null || echo 0)
    if [[ "$count" -eq 1 ]]; then
      local fname; fname=$(basename "$files")
      local cat_inferred; cat_inferred=$(jq --arg cat "$cat" --arg fname "$fname" '
        [.history[] | select(.category == $cat and .file == "legacy")] | length
      ' "$tmp")
      if [[ "$cat_inferred" -gt 0 ]]; then
        jq --arg cat "$cat" --arg fname "$fname" '
          .history |= [.[] |
            if (.category == $cat and .file == "legacy") then .file = $fname
            else . end
          ]
        ' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
        inferred=$((inferred + cat_inferred))
        echo "  📎 $cat → $fname ($cat_inferred entries)"
      fi
    fi
  done

  local legacy=$((missing - inferred))
  mv "$tmp" "$tracker_file"
  echo ""
  echo "Results:"
  echo "  Inferred: $inferred entries (single-file categories)"
  echo "  Legacy:   $legacy entries (marked as 'legacy' — original pick unknowable)"
  echo "  Total:    $missing entries backfilled"
}

cmd_audit() {
  local min_files=${1:-3}
  echo "=== Meme Audit (min $min_files files per category) ==="
  echo ""

  local total_cats=0 low_cats=0 empty_cats=0 ok_cats=0
  local -a low_list=() empty_list=()

  for dir in "$MEMES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local name; name=$(basename "$dir")
    [[ "$name" == .* ]] && continue
    total_cats=$((total_cats + 1))

    local count; count=$(find "$dir" -maxdepth 1 -type f \( -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.webp' \) | wc -l)

    if [[ $count -eq 0 ]]; then
      empty_cats=$((empty_cats + 1))
      empty_list+=("$name")
    elif [[ $count -lt $min_files ]]; then
      low_cats=$((low_cats + 1))
      low_list+=("$name ($count files)")
    else
      ok_cats=$((ok_cats + 1))
    fi
  done

  # Check for tag coverage
  local tags_file="$MEMES_DIR/tags.json"
  local untagged=0
  local -a untagged_list=()
  if [[ -f "$tags_file" ]] && command -v jq &>/dev/null; then
    for dir in "$MEMES_DIR"/*/; do
      [[ -d "$dir" ]] || continue
      local name; name=$(basename "$dir")
      [[ "$name" == .* ]] && continue
      local files; files=$(find "$dir" -maxdepth 1 -type f \( -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.webp' \) -printf '%f\n')
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local key="$name/$f"
        local has_tags; has_tags=$(jq -r --arg key "$key" 'if .[$key] then (.[$key] | length) else 0 end' "$tags_file" 2>/dev/null || echo 0)
        if [[ "$has_tags" == "0" || -z "$has_tags" ]]; then
          untagged=$((untagged + 1))
          untagged_list+=("$key")
        fi
      done <<< "$files"
    done
  fi

  # Summary
  echo "Category health:"
  echo "  ✅ $ok_cats categories OK (≥$min_files files)"
  if [[ $low_cats -gt 0 ]]; then
    echo "  ⚠️  $low_cats categories LOW variety:"
    for item in "${low_list[@]}"; do
      echo "     → $item"
    done
  fi
  if [[ $empty_cats -gt 0 ]]; then
    echo "  ❌ $empty_cats categories EMPTY:"
    for item in "${empty_list[@]}"; do
      echo "     → $item"
    done
  fi
  echo "  Total: $total_cats categories"
  echo ""

  # Tag coverage
  if [[ -f "$tags_file" ]]; then
    if [[ $untagged -gt 0 ]]; then
      echo "Tag coverage:"
      echo "  ⚠️  $untagged files missing tags:"
      local shown=0
      for item in "${untagged_list[@]}"; do
        echo "     → $item"
        shown=$((shown + 1))
        [[ $shown -ge 10 ]] && { echo "     ... and $((untagged - shown)) more"; break; }
      done
    else
      echo "Tag coverage: ✅ all files tagged"
    fi
  else
    echo "Tag coverage: ⚠️  No tags.json found"
  fi
  echo ""

  # Total file count
  local total_files; total_files=$(find "$MEMES_DIR" -mindepth 2 -maxdepth 2 -type f \( -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.webp' \) | wc -l)
  echo "Total meme files: $total_files"

  # Exit code: 0 if healthy, 1 if issues found
  [[ $low_cats -eq 0 && $empty_cats -eq 0 ]] && return 0 || return 1
}

cmd_trending() {
  local days=${1:-7}
  local tracker_file="$MEMES_DIR/meme-tracker.json"
  if ! command -v jq &>/dev/null; then
    echo "Error: jq required for trending" >&2; exit 1
  fi
  if [[ ! -f "$tracker_file" ]]; then
    echo "Error: No tracker file at $tracker_file" >&2; exit 1
  fi

  # Calculate date boundaries
  local now_epoch; now_epoch=$(date +%s)
  local recent_start; recent_start=$(date -d "@$((now_epoch - days * 86400))" +%Y-%m-%d)
  local prev_start; prev_start=$(date -d "@$((now_epoch - days * 2 * 86400))" +%Y-%m-%d)
  local today; today=$(date +%Y-%m-%d)

  echo "=== Meme Trending (${days}d windows) ==="
  echo "Recent:   $recent_start → $today"
  echo "Previous: $prev_start → $(date -d "@$((now_epoch - days * 86400 - 86400))" +%Y-%m-%d)"
  echo ""

  # jq: count per category in each window, compute delta
  jq -r --arg rs "$recent_start" --arg ps "$prev_start" --arg td "$today" '
    def date_of: (. // "")[0:10];
    [.history[] | {cat: .category, d: ((.time // "") | date_of)}] |
    group_by(.cat) | map({
      cat: .[0].cat,
      recent: [.[] | select(.d >= $rs and .d <= $td)] | length,
      prev:   [.[] | select(.d >= $ps and .d < $rs)] | length
    }) |
    map(. + {delta: (.recent - .prev)}) |
    sort_by(-.delta) |
    .[] | "\(.cat)\t\(.recent)\t\(.prev)\t\(.delta)"
  ' "$tracker_file" | {
    echo "Category               Recent  Prev  Delta"
    echo "─────────────────────  ──────  ────  ─────"
    while IFS=$'\t' read -r cat recent prev delta; do
      local arrow=""
      if [[ $delta -gt 0 ]]; then arrow="📈 +$delta"
      elif [[ $delta -lt 0 ]]; then arrow="📉 $delta"
      else arrow="  ─"
      fi
      printf "%-23s %6s  %4s  %s\n" "$cat" "$recent" "$prev" "$arrow"
    done
  }

  echo ""

  # Highlight top risers and fallers
  local top_riser; top_riser=$(jq -r --arg rs "$recent_start" --arg ps "$prev_start" --arg td "$today" '
    def date_of: (. // "")[0:10];
    [.history[] | {cat: .category, d: ((.time // "") | date_of)}] |
    group_by(.cat) | map({
      cat: .[0].cat,
      recent: [.[] | select(.d >= $rs and .d <= $td)] | length,
      prev:   [.[] | select(.d >= $ps and .d < $rs)] | length
    }) |
    map(. + {delta: (.recent - .prev)}) |
    sort_by(-.delta) | .[0] |
    if .delta > 0 then "🔥 Rising: \(.cat) (+\(.delta))" else "No risers" end
  ' "$tracker_file")

  local top_faller; top_faller=$(jq -r --arg rs "$recent_start" --arg ps "$prev_start" --arg td "$today" '
    def date_of: (. // "")[0:10];
    [.history[] | {cat: .category, d: ((.time // "") | date_of)}] |
    group_by(.cat) | map({
      cat: .[0].cat,
      recent: [.[] | select(.d >= $rs and .d <= $td)] | length,
      prev:   [.[] | select(.d >= $ps and .d < $rs)] | length
    }) |
    map(. + {delta: (.recent - .prev)}) |
    sort_by(.delta) | .[0] |
    if .delta < 0 then "❄️  Falling: \(.cat) (\(.delta))" else "No fallers" end
  ' "$tracker_file")

  echo "$top_riser"
  echo "$top_faller"
}

cmd_health() {
  echo "=== Meme Health Report ==="
  echo ""

  local issues=0

  # --- 1. Category audit (inline, not calling cmd_audit to control output) ---
  local total_cats=0 low_cats=0 total_files=0
  local min_files=3
  for dir in "$MEMES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local name; name=$(basename "$dir")
    [[ "$name" == .* ]] && continue
    total_cats=$((total_cats + 1))
    local count; count=$(find "$dir" -maxdepth 1 -type f \( -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.webp' \) | wc -l)
    total_files=$((total_files + count))
    [[ $count -lt $min_files ]] && low_cats=$((low_cats + 1))
  done
  if [[ $low_cats -eq 0 ]]; then
    echo "📁 Categories: ✅ $total_cats categories, all ≥$min_files files ($total_files total)"
  else
    echo "📁 Categories: ⚠️  $low_cats/$total_cats below $min_files files ($total_files total)"
    issues=$((issues + 1))
  fi

  # --- 2. Tag coverage ---
  local tags_file="$MEMES_DIR/tags.json"
  if [[ -f "$tags_file" ]] && command -v jq &>/dev/null; then
    local untagged=0
    for dir in "$MEMES_DIR"/*/; do
      [[ -d "$dir" ]] || continue
      local name; name=$(basename "$dir")
      [[ "$name" == .* ]] && continue
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local key="$name/$f"
        local has_tags; has_tags=$(jq -r --arg key "$key" 'if .[$key] then (.[$key] | length) else 0 end' "$tags_file" 2>/dev/null || echo 0)
        [[ "$has_tags" == "0" || -z "$has_tags" ]] && untagged=$((untagged + 1))
      done < <(find "$dir" -maxdepth 1 -type f \( -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.webp' \) -printf '%f\n')
    done
    if [[ $untagged -eq 0 ]]; then
      echo "🏷️  Tags: ✅ all $total_files files tagged"
    else
      echo "🏷️  Tags: ⚠️  $untagged files missing tags"
      issues=$((issues + 1))
    fi
  else
    echo "🏷️  Tags: ⚠️  tags.json not found or jq unavailable"
    issues=$((issues + 1))
  fi

  # --- 3. Tracker integrity ---
  local tracker_file="$MEMES_DIR/meme-tracker.json"
  if [[ -f "$tracker_file" ]] && command -v jq &>/dev/null; then
    local history_len; history_len=$(jq '.history | length' "$tracker_file")
    local total_sent; total_sent=$(jq '.totalSent' "$tracker_file")
    local tracker_issues=0
    local tracker_details=""

    # Check totalSent + totalFailed = history length
    local total_failed; total_failed=$(jq '.totalFailed // 0' "$tracker_file")
    local failed_in_hist; failed_in_hist=$(jq '[.history[] | select(.result == "failed")] | length' "$tracker_file")
    local success_in_hist; success_in_hist=$(jq '[.history[] | select(.result == "success" or .result == "sent")] | length' "$tracker_file")
    if [[ "$total_sent" != "$success_in_hist" ]]; then
      tracker_details+="     totalSent=$total_sent but $success_in_hist successes in history\n"
      tracker_issues=$((tracker_issues + 1))
    fi
    if [[ "$total_failed" != "$failed_in_hist" ]]; then
      tracker_details+="     totalFailed=$total_failed but $failed_in_hist failures in history\n"
      tracker_issues=$((tracker_issues + 1))
    fi

    # Check counts object matches history category tallies
    local counts_match; counts_match=$(jq '
      (.counts // {}) as $counts |
      ([.history[] | select(.result == "success" or .result == "sent") | .category] | group_by(.) | map({key: .[0], value: length}) | from_entries) as $actual |
      if ($counts | length) == 0 and ($actual | length) > 0 then "stale"
      elif $counts == $actual then "ok"
      else "mismatch" end' "$tracker_file")
    if [[ "$counts_match" == '"stale"' || "$counts_match" == '"mismatch"' ]]; then
      tracker_details+="     counts object out of sync with history\n"
      tracker_issues=$((tracker_issues + 1))
    fi

    # Check for missing required fields (category, time)
    local missing_cat; missing_cat=$(jq '[.history[] | select(.category == null or .category == "")] | length' "$tracker_file")
    local missing_time; missing_time=$(jq '[.history[] | select(.time == null or .time == "")] | length' "$tracker_file")
    [[ "$missing_cat" -gt 0 ]] && { tracker_details+="     $missing_cat entries missing category\n"; tracker_issues=$((tracker_issues + 1)); }
    [[ "$missing_time" -gt 0 ]] && { tracker_details+="     $missing_time entries missing time\n"; tracker_issues=$((tracker_issues + 1)); }

    # Check for legacy/unresolvable file entries
    local legacy_files; legacy_files=$(jq '[.history[] | select(.file == "legacy")] | length' "$tracker_file")
    local unresolvable_files; unresolvable_files=$(jq '[.history[] | select(.file == "unresolvable")] | length' "$tracker_file")

    if [[ $tracker_issues -eq 0 ]]; then
      local info="$history_len entries"
      [[ "$legacy_files" -gt 0 ]] && info+=", $legacy_files legacy"
      [[ "$unresolvable_files" -gt 0 ]] && info+=", $unresolvable_files unresolvable (expired)"
      echo "📊 Tracker: ✅ $info"
    else
      echo "📊 Tracker: ⚠️  $tracker_issues issue(s)"
      echo -e "$tracker_details"
      issues=$((issues + tracker_issues))
    fi
  else
    echo "📊 Tracker: ⚠️  tracker file not found"
    issues=$((issues + 1))
  fi

  # --- 4. Oversized files (>2MB) ---
  local oversized=0
  local -a oversized_list=()
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local size_bytes; size_bytes=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if [[ $size_bytes -gt 2097152 ]]; then
      oversized=$((oversized + 1))
      local size_mb; size_mb=$(awk "BEGIN{printf \"%.1f\", $size_bytes/1048576}")
      local rel; rel=$(realpath --relative-to="$MEMES_DIR" "$f")
      oversized_list+=("$rel (${size_mb}MB)")
    fi
  done < <(find "$MEMES_DIR" -mindepth 2 -maxdepth 2 -type f \( -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.webp' \))
  if [[ $oversized -eq 0 ]]; then
    echo "📏 File sizes: ✅ all under 2MB"
  else
    echo "📏 File sizes: ⚠️  $oversized files over 2MB:"
    for item in "${oversized_list[@]}"; do
      echo "     → $item"
    done
    issues=$((issues + 1))
  fi

  # --- 5. LFS pointer check ---
  local lfs_pointers=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local size_bytes; size_bytes=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if [[ $size_bytes -lt 1024 ]] && grep -q 'oid sha256' "$f" 2>/dev/null; then
      lfs_pointers=$((lfs_pointers + 1))
    fi
  done < <(find "$MEMES_DIR" -mindepth 2 -maxdepth 2 -type f \( -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.webp' \))
  if [[ $lfs_pointers -gt 0 ]]; then
    echo "🔗 LFS: ⚠️  $lfs_pointers files are LFS pointers (run: cd $MEMES_DIR && git lfs pull)"
    issues=$((issues + 1))
  fi

  # --- 6. Style diversity (>70% single-style per non-exempt category) ---
  local tags_file="$MEMES_DIR/tags.json"
  if [[ -f "$tags_file" ]] && command -v jq &>/dev/null && jq -e '._styles' "$tags_file" &>/dev/null; then
    local style_flagged
    style_flagged=$(jq '[
      ._styles as $s |
      [$s | to_entries[] | select(.key | contains("/")) | {cat: (.key | split("/")[0]), style: .value}]
      | group_by(.cat)
      | .[] | {cat: .[0].cat, total: length, max: ([group_by(.style) | .[] | length] | max)}
      | select((.max * 100 / .total) > 70)
      | select(.cat | test("^cute-animals$|^animal") | not)
    ] | length' "$tags_file")
    if [[ "$style_flagged" -gt 0 ]]; then
      echo "🎨 Style diversity: ⚠️  $style_flagged categories >70% single-style"
      issues=$((issues + 1))
    else
      echo "🎨 Style diversity: ✅ all categories balanced"
    fi
  fi

  # --- 7. Dormant categories (0 sends in last 30 days) ---
  if [[ -f "$MEMES_DIR/meme-tracker.json" ]] && command -v jq &>/dev/null; then
    local cutoff; cutoff=$(date -d '30 days ago' --iso-8601=seconds 2>/dev/null || date -v-30d +%Y-%m-%dT%H:%M:%S%z)
    # Build category list from directories
    local all_cats_json="[]"
    all_cats_json=$(for dir in "$MEMES_DIR"/*/; do [[ -d "$dir" ]] && basename "$dir"; done | grep -v '^\.\|^$' | jq -R -s 'split("\n") | map(select(length > 0))')
    local dormant_cats
    dormant_cats=$(jq -r --arg cutoff "$cutoff" --argjson all_cats "$all_cats_json" '
      [.history[] | select(.time >= $cutoff and (.result == "success" or .result == "sent")) | .category] | unique as $used |
      [$all_cats[] | select(. as $c | $used | index($c) | not)] | sort | join(", ")
    ' "$MEMES_DIR/meme-tracker.json")
    if [[ -n "$dormant_cats" && "$dormant_cats" != "" ]]; then
      local dormant_count; dormant_count=$(echo "$dormant_cats" | tr ',' '\n' | wc -w)
      echo "💤 Dormant: ⚠️  $dormant_count categories with 0 sends in 30d: $dormant_cats"
      issues=$((issues + 1))
    else
      echo "💤 Dormant: ✅ all categories active in last 30d"
    fi
  fi

  # --- Summary ---
  echo ""
  if [[ $issues -eq 0 ]]; then
    echo "✅ All healthy — $total_cats categories, $total_files files"
  else
    echo "⚠️  $issues issue(s) found"
  fi
  return $([[ $issues -eq 0 ]] && echo 0 || echo 1)
}

cmd_wake() {
  # Pick a random file from the most dormant category (longest since last send)
  # --send: also send to channel (default: discord #agent-memes)
  # --to TARGET: override send target
  # --caption TEXT: override caption
  local do_send=false send_to="" send_caption="" send_channel=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --send)    do_send=true; shift ;;
      --to)      send_to="$2"; shift 2 ;;
      --caption) send_caption="$2"; shift 2 ;;
      --channel) send_channel="$2"; shift 2 ;;
      *)         shift ;;
    esac
  done

  local tracker_file="$MEMES_DIR/meme-tracker.json"
  if ! command -v jq &>/dev/null; then
    echo "Error: jq required for wake" >&2; exit 1
  fi
  if [[ ! -f "$tracker_file" ]]; then
    echo "Error: No tracker file at $tracker_file" >&2; exit 1
  fi

  # Build list of all categories from directories
  local -a all_cats=()
  for dir in "$MEMES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local name; name=$(basename "$dir")
    [[ "$name" == .* ]] && continue
    all_cats+=("$name")
  done

  # Find the most dormant category: never sent > oldest last send
  local most_dormant=""
  local oldest_time="9999-99-99"
  for cat in "${all_cats[@]}"; do
    local last_send
    last_send=$(jq -r --arg cat "$cat" '
      [.history[] | select(.category == $cat and (.result == "success" or .result == "sent")) | .time]
      | last // ""' "$tracker_file" 2>/dev/null)
    if [[ -z "$last_send" || "$last_send" == "null" ]]; then
      # Never sent — immediately pick this one
      most_dormant="$cat"
      oldest_time=""
      break
    elif [[ "$last_send" < "$oldest_time" ]]; then
      oldest_time="$last_send"
      most_dormant="$cat"
    fi
  done

  if [[ -z "$most_dormant" ]]; then
    echo "Error: No categories found" >&2; exit 1
  fi

  # Pick a random file from the dormant category (reuse cmd_pick logic)
  local picked
  picked=$(cmd_pick "$most_dormant")
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "Error: Failed to pick from '$most_dormant'" >&2; exit 1
  fi

  echo "💤 Waking dormant category: $most_dormant (last send: ${oldest_time:-never})" >&2

  if [[ "$do_send" == true ]]; then
    # Auto-send to channel
    local caption="${send_caption:-💤 meme of the day — waking $most_dormant}"
    local -a send_args=("$most_dormant" "$caption")
    [[ -n "$send_to" ]] && send_args+=("--to" "$send_to")
    [[ -n "$send_channel" ]] && send_args+=("--channel" "$send_channel")
    cmd_send "${send_args[@]}"
  else
    echo "$picked"
  fi
}

cmd_dormant_blast() {
  # Send up to N dormant memes (1 per category, ordered by staleness)
  # Usage: memes dormant-blast [n] [--to TARGET] [--channel CHANNEL] [--caption TEXT]
  local max_n=1 send_to="" send_channel="" send_caption=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to)      send_to="$2"; shift 2 ;;
      --channel) send_channel="$2"; shift 2 ;;
      --caption) send_caption="$2"; shift 2 ;;
      [0-9]*)    max_n="$1"; shift ;;
      *)         shift ;;
    esac
  done
  [[ "$max_n" -lt 1 ]] && max_n=1

  local tracker_file="$MEMES_DIR/meme-tracker.json"
  if ! command -v jq &>/dev/null; then
    echo "Error: jq required for dormant-blast" >&2; exit 1
  fi
  if [[ ! -f "$tracker_file" ]]; then
    echo "Error: No tracker file at $tracker_file" >&2; exit 1
  fi

  # Build list of all categories from directories
  local -a all_cats=()
  for dir in "$MEMES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local name; name=$(basename "$dir")
    [[ "$name" == .* ]] && continue
    all_cats+=("$name")
  done

  # Build sorted dormancy list: category|last_send_time
  local -a dormancy_list=()
  for cat in "${all_cats[@]}"; do
    local last_send
    last_send=$(jq -r --arg cat "$cat" '
      [.history[] | select(.category == $cat and (.result == "success" or .result == "sent")) | .time]
      | last // ""' "$tracker_file" 2>/dev/null)
    if [[ -z "$last_send" || "$last_send" == "null" ]]; then
      dormancy_list+=("0000-00-00|$cat")
    else
      dormancy_list+=("$last_send|$cat")
    fi
  done

  # Sort by time ascending (oldest = most dormant first)
  IFS=$'\n' sorted=($(printf '%s\n' "${dormancy_list[@]}" | sort)); unset IFS

  local sent=0
  for entry in "${sorted[@]}"; do
    [[ $sent -ge $max_n ]] && break
    local cat="${entry#*|}"
    local last_time="${entry%%|*}"

    echo "💤 [$((sent+1))/$max_n] Waking dormant: $cat (last: ${last_time:-never})" >&2

    # Build send args
    local caption="${send_caption:-💤 dormant blast — waking $cat}"
    local -a send_args=("$cat" "$caption")
    [[ -n "$send_to" ]] && send_args+=("--to" "$send_to")
    [[ -n "$send_channel" ]] && send_args+=("--channel" "$send_channel")

    if cmd_send "${send_args[@]}"; then
      sent=$((sent + 1))
    else
      echo "⚠️  Failed to send $cat, skipping" >&2
    fi

    # Small delay between sends to avoid rate limiting
    [[ $sent -lt $max_n ]] && sleep 1
  done

  echo "✅ Dormant blast complete: $sent/$max_n categories woken" >&2
}

cmd_normalize() {
  local tracker_file="$MEMES_DIR/meme-tracker.json"
  if ! command -v jq &>/dev/null; then
    echo "Error: jq required for normalize" >&2; exit 1
  fi
  if [[ ! -f "$tracker_file" ]]; then
    echo "Error: No tracker file at $tracker_file" >&2; exit 1
  fi

  # Count issues before fix
  local before_issues; before_issues=$(jq '[
    (.history[] | select(.time == null or .time == "")),
    (.history[] | select(.category == null or .category == "")),
    (.history[] | select(.action == null or .action == "")),
    (.history[] | select(.result == null or .result == "")),
    (.history[] | select(.method == null or .method == "")),
    (.history[] | select(.file == "unknown"))
  ] | length' "$tracker_file")

  local tmp; tmp=$(mktemp)
  jq '
    .history = [.history[] |
      # Convert old date+time format to ISO time (handle null gracefully)
      (if (.time == null or .time == "") then
         (if .date then (.date + "T00:00:00+08:00") else "1970-01-01T00:00:00+00:00" end)
       elif (.time | test("^[0-9]{4}-")) then .time
       elif .date and .time then (.date + "T" + .time + ":00+08:00")
       else .time
       end) as $normalized_time |
      # Apply normalizations
      .time = $normalized_time |
      del(.date) |
      .category = (.category // "unknown") |
      .action = (.action // "send") |
      .result = (.result // "success") |
      .method = (.method // "manual") |
      (if .file == "unknown" then .file = "legacy" else . end)
    ]
  ' "$tracker_file" > "$tmp" && mv "$tmp" "$tracker_file"

  # Count issues after fix
  local after_issues; after_issues=$(jq '[
    (.history[] | select(.time == null or .time == "")),
    (.history[] | select(.category == null or .category == "")),
    (.history[] | select(.action == null or .action == "")),
    (.history[] | select(.result == null or .result == "")),
    (.history[] | select(.method == null or .method == "")),
    (.history[] | select(.file == "unknown"))
  ] | length' "$tracker_file")

  local fixed=$((before_issues - after_issues))
  if [[ $fixed -gt 0 ]]; then
    echo "✅ Normalized tracker: fixed $fixed field issues"
    # Re-sync counts after normalization
    cmd_sync
  else
    echo "✅ Tracker already normalized, no issues found"
  fi
}

cmd_sync() {
  local tracker_file="$MEMES_DIR/meme-tracker.json"
  if ! command -v jq &>/dev/null; then
    echo "Error: jq required for sync" >&2; exit 1
  fi
  if [[ ! -f "$tracker_file" ]]; then
    echo "Error: No tracker file at $tracker_file" >&2; exit 1
  fi
  local tmp; tmp=$(mktemp)
  jq '.totalSent = ([.history[] | select(.result == "success" or .result == "sent")] | length) | .totalFailed = ([.history[] | select(.result == "failed")] | length) | .counts = ([.history[] | select(.result == "success" or .result == "sent") | .category] | group_by(.) | map({key: .[0], value: length}) | from_entries) | .consecutiveFailures = ([.history | to_entries | reverse | .[] | select(.value.result == "success" or .value.result == "sent") | .key] | first // -1) as $last_ok | if $last_ok == (.history | length - 1) then 0 else ((.history | length) - 1 - $last_ok) end' "$tracker_file" > "$tmp" && mv "$tmp" "$tracker_file"
  local total; total=$(jq '.totalSent' "$tracker_file")
  local counts_sum; counts_sum=$(jq '[.counts | to_entries[] | .value] | add' "$tracker_file")
  echo "✅ Tracker synced: totalSent=$total, counts_sum=$counts_sum, all derived from history"
}

cmd_expire_legacy() {
  # Mark remaining 'legacy' file entries as permanently unresolvable.
  # These are old entries from before _track_send recorded filenames.
  # The original RANDOM pick was ephemeral and cannot be reconstructed.
  # Pass --dry-run to preview without modifying.
  local dry_run=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=true; shift ;;
      *)         shift ;;
    esac
  done

  local tracker_file="$MEMES_DIR/meme-tracker.json"
  if ! command -v jq &>/dev/null; then
    echo "Error: jq required for expire-legacy" >&2; exit 1
  fi
  if [[ ! -f "$tracker_file" ]]; then
    echo "Error: No tracker file at $tracker_file" >&2; exit 1
  fi

  # Count current legacy entries
  local legacy_count
  legacy_count=$(jq '[.history[] | select(.file == "legacy")] | length' "$tracker_file")
  if [[ "$legacy_count" -eq 0 ]]; then
    echo "✅ No legacy entries to expire"
    return 0
  fi

  echo "=== Expire Legacy ==="
  echo "Found $legacy_count entries with file=\"legacy\""
  echo ""

  # Attempt to resolve: check if any legacy entry has a caption/note that
  # matches an actual filename in the category directory (unlikely but thorough)
  local resolved=0
  local tmp; tmp=$(mktemp)
  cp "$tracker_file" "$tmp"

  # Build a lookup of category → filenames
  local -A cat_files=()
  for dir in "$MEMES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local name; name=$(basename "$dir")
    [[ "$name" == .* ]] && continue
    local fnames
    fnames=$(find "$dir" -maxdepth 1 -type f \( -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.webp' \) -printf '%f\n' 2>/dev/null | tr '\n' '|')
    cat_files["$name"]="$fnames"
  done

  # Check each legacy entry for filename hints in note/caption fields
  local match_jq=''
  for cat in "${!cat_files[@]}"; do
    IFS='|' read -ra flist <<< "${cat_files[$cat]}"
    for fname in "${flist[@]}"; do
      [[ -z "$fname" ]] && continue
      local base="${fname%.*}"  # strip extension
      # Build jq filter to match filename references in note/caption
      match_jq=$(jq --arg cat "$cat" --arg fname "$fname" --arg base "$base" '
        .history |= [.[] |
          if (.file == "legacy" and .category == $cat and
              ((.note // "" | test($base; "i")) or (.caption // "" | test($base; "i"))))
          then .file = $fname
          else . end
        ]' "$tmp" 2>/dev/null)
      if [[ -n "$match_jq" ]]; then
        echo "$match_jq" > "$tmp"
      fi
    done
  done

  # Count how many got resolved by filename matching
  local remaining_legacy
  remaining_legacy=$(jq '[.history[] | select(.file == "legacy")] | length' "$tmp")
  resolved=$((legacy_count - remaining_legacy))
  if [[ $resolved -gt 0 ]]; then
    echo "📎 Resolved $resolved entries by filename matching in notes/captions"
  fi

  # Mark all remaining legacy as "unresolvable"
  jq '.history |= [.[] | if .file == "legacy" then .file = "unresolvable" else . end]' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"

  echo ""
  echo "Results:"
  echo "  Resolved:      $resolved entries (matched filename in note/caption)"
  echo "  Unresolvable:  $remaining_legacy entries (original pick was ephemeral)"
  echo "  Total expired: $legacy_count"

  if [[ "$dry_run" == true ]]; then
    echo ""
    echo "🔍 Dry run — no changes written"
    rm -f "$tmp"
    return 0
  fi

  # Write back
  mv "$tmp" "$tracker_file"

  # Re-sync derived fields
  cmd_sync

  echo ""
  echo "✅ All legacy entries expired. Tracker synced."
}

cmd_quality() {
  local issues=0
  local tag_file="$MEMES_DIR/tags.json"

  echo "🔍 Meme Quality Check"
  echo "===================="
  echo ""

  # 1. Cross-category duplicate filenames
  echo "## 1. Cross-category duplicate filenames"
  local dupes
  dupes=$(cd "$MEMES_DIR" && find . -maxdepth 2 -type f \( -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.webp' \) \
    | sed 's|^\./||' | awk -F/ '{print $NF}' | sort | uniq -d)
  if [[ -n "$dupes" ]]; then
    while IFS= read -r fname; do
      local locations
      locations=$(cd "$MEMES_DIR" && find . -maxdepth 2 -name "$fname" | sed 's|^\./||' | paste -sd', ')
      # Check if files are actually identical (same content)
      local md5s
      md5s=$(cd "$MEMES_DIR" && find . -maxdepth 2 -name "$fname" -exec md5sum {} \; | awk '{print $1}' | sort -u | wc -l)
      if [[ "$md5s" -eq 1 ]]; then
        echo "  ⚠️  $fname (IDENTICAL content) → $locations"
        echo "     💡 Suggest: rename to <category>-specific name or deduplicate"
      else
        echo "  ℹ️  $fname (different content) → $locations"
        echo "     💡 Suggest: rename to distinguish (e.g. category-$fname)"
      fi
      issues=$((issues + 1))
    done <<< "$dupes"
  else
    echo "  ✅ No duplicate filenames across categories"
  fi
  echo ""

  # 2. Generic/uninformative filenames
  echo "## 2. Generic filenames"
  local generic
  generic=$(cd "$MEMES_DIR" && find . -maxdepth 2 -type f \( -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.webp' \) \
    | sed 's|^\./||' \
    | grep -iP '(^|/)(giphy|tenor|download|image|unnamed|untitled|IMG_|photo|video|original|source|tmp|temp|test)[^/]*\.' || true)
  if [[ -n "$generic" ]]; then
    while IFS= read -r gf; do
      local base
      base=$(basename "$gf" | sed 's/\.[^.]*$//')
      local cat_name
      cat_name=$(dirname "$gf")
      echo "  ⚠️  $gf"
      echo "     💡 Suggest: rename to ${cat_name}-${base// /-}.gif or a descriptive name"
      issues=$((issues + 1))
    done <<< "$generic"
  else
    echo "  ✅ No generic filenames found"
  fi
  echo ""

  # 3. Near-duplicate filenames (same base name ignoring prefix/suffix patterns)
  echo "## 3. Near-duplicate filenames (similar names)"
  local near_dupes_found=false
  # Group by base word (strip common prefixes like anime-, cat-, etc. and suffixes like -2, -v2)
  local all_files
  all_files=$(cd "$MEMES_DIR" && find . -maxdepth 2 -type f \( -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.webp' \) | sed 's|^\./||' | sort)
  # Find files in SAME category with very similar names
  local prev_cat="" prev_base="" prev_file=""
  while IFS= read -r f; do
    local cat
    cat=$(dirname "$f")
    local base
    base=$(basename "$f" | sed 's/\.[^.]*$//')
    if [[ "$cat" == "$prev_cat" && -n "$prev_base" ]]; then
      # Check if one name is a prefix of the other (e.g. wave and wave-2)
      if [[ "$base" == "$prev_base"* || "$prev_base" == "$base"* ]] && [[ "$base" != "$prev_base" ]]; then
        echo "  ⚠️  Same category '$cat': $prev_file ↔ $(basename "$f")"
        echo "     💡 Check if these are redundant or rename for clarity"
        near_dupes_found=true
        issues=$((issues + 1))
      fi
    fi
    prev_cat="$cat"
    prev_base="$base"
    prev_file=$(basename "$f")
  done <<< "$all_files"
  if [[ "$near_dupes_found" == false ]]; then
    echo "  ✅ No near-duplicate filenames in same category"
  fi
  echo ""

  # 4. Missing tags (files without tags.json entries)
  echo "## 4. Untagged files"
  local untagged=0
  if [[ -f "$tag_file" ]]; then
    while IFS= read -r f; do
      local tag_key="$f"
      local has_tag
      has_tag=$(jq -r --arg k "$tag_key" 'has($k)' "$tag_file" 2>/dev/null || echo "false")
      if [[ "$has_tag" != "true" ]]; then
        echo "  ⚠️  $f — not in tags.json"
        untagged=$((untagged + 1))
        issues=$((issues + 1))
      fi
    done < <(cd "$MEMES_DIR" && find . -maxdepth 2 -type f \( -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.webp' \) | sed 's|^\./||' | sort)
    if [[ "$untagged" -eq 0 ]]; then
      echo "  ✅ All $( cd "$MEMES_DIR" && find . -maxdepth 2 -type f \( -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.webp' \) | wc -l) files tagged"
    else
      echo "  Total untagged: $untagged"
    fi
  else
    echo "  ⚠️  tags.json not found — cannot check"
    issues=$((issues + 1))
  fi
  echo ""

  # 5. Missing styles (files without _styles entries)
  echo "## 5. Unstyled files"
  local unstyled=0
  if [[ -f "$tag_file" ]]; then
    while IFS= read -r f; do
      local has_style
      has_style=$(jq -r --arg k "$f" '._styles | has($k)' "$tag_file" 2>/dev/null || echo "false")
      if [[ "$has_style" != "true" ]]; then
        echo "  ⚠️  $f — not in _styles"
        unstyled=$((unstyled + 1))
        issues=$((issues + 1))
      fi
    done < <(cd "$MEMES_DIR" && find . -maxdepth 2 -type f \( -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.webp' \) | sed 's|^\./||' | sort)
    if [[ "$unstyled" -eq 0 ]]; then
      echo "  ✅ All files have style entries"
    else
      echo "  Total unstyled: $unstyled"
    fi
  else
    echo "  ⚠️  tags.json not found — cannot check"
  fi
  echo ""

  # Summary
  echo "==================="
  if [[ "$issues" -eq 0 ]]; then
    echo "✅ Quality check passed — no issues found"
    return 0
  else
    echo "⚠️  Found $issues issue(s) to review"
    return 1
  fi
}

[[ $# -lt 1 ]] && usage
case "$1" in
  wake)            shift; cmd_wake "$@" ;;
  dormant-blast)   shift; cmd_dormant_blast "$@" ;;
  sync)            cmd_sync ;;
  normalize)       cmd_normalize ;;
  stats)           cmd_stats ;;
  search)          shift; cmd_search "$@" ;;
  backfill-files)  cmd_backfill_files ;;
  expire-legacy)   shift; cmd_expire_legacy "$@" ;;
  audit)      shift; cmd_audit "$@" ;;
  health)     cmd_health ;;
  trending)   shift; cmd_trending "$@" ;;
  pick)       shift; cmd_pick "$@" ;;
  list)       shift; cmd_list "$@" ;;
  random)     cmd_random ;;
  send)       shift; cmd_send "$@" ;;
  categories)     cmd_categories ;;
  quality)   cmd_quality ;;
  -h|--help)      usage ;;
  *)              echo "Unknown command: $1" >&2; usage ;;
esac
