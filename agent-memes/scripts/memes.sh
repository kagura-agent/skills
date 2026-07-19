#!/usr/bin/env bash
# memes - Agent meme library manager with multi-platform send
set -euo pipefail

MEMES_DIR="${MEMES_DIR:-$HOME/.openclaw/workspace/memes}"
# Contextual categories: time-of-day/situation-bound, expected to go stale outside their natural triggers
MEMES_CONTEXTUAL_CATS=(greeting-morning greeting-night greeting-hello greeting-bye)
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
  send <category> [caption] [--to target] [--channel platform] [--account name] [--file path]
  categories              List all categories with counts
  cron-check [--threshold N] [--dry-run]  Autonomous cron: review --full + auto-wake stalest (default 14d)
  stats                   Show usage stats from tracker (frequency, last-used)
  failures [n] [--json]   Show last N failures with error messages (default 10)
  search <query>          Search memes by tags (fuzzy cross-category match)
  freshness [--json]      Per-category staleness; >7d general, >14d contextual (greeting-*)
  backfill-files          Fill missing 'file' field in old tracker entries
  normalize               Fix malformed tracker entries (missing fields, old date format)
  expire-legacy           Mark unresolvable 'legacy' file entries as permanently expired
  audit [min_files]       Check category health and tag coverage (default min: 3)
  health                  Combined health check: audit + tracker integrity + oversized files
  quality                 Check for duplicate filenames, generic names, near-dupes, missing tags/styles
  lint [--fix]            Check for untagged/unstyled files; --fix auto-adds defaults
  coverage [--json] [--weak]  Tag/style coverage % per category; --weak filters to issues only
  review                  Cron-friendly review: coverage check + tracker log + remediation hints
  dedup [--fix]            Find exact-duplicate files (md5); --fix removes dupes and merges tags
  retire <src> <tgt> [--dry-run]  Merge src category into tgt (move files, update tags/tracker)
  suggest <text>          Suggest top-3 memes by mood/text (--send to auto-send top pick)
  gallery [--output FILE]  Generate HTML gallery page for visual meme browsing

Platforms with fast send: discord, feishu, telegram
Other platforms fall back to: openclaw message send

Examples:
  memes send happy "好开心！" --to <channel_id>         # → Discord
  memes send facepalm --to channel:1491636222853124176  # → Discord #work
  memes send feishu cute-animals "看！" --to user:xxx   # → Feishu
  memes send telegram wow --to 12345678                 # → Telegram
  memes send happy --file memes/happy/dance.gif          # Send a specific file
EOF
  exit 1
}

cmd_categories() {
  [[ ! -d "$MEMES_DIR" ]] && { echo "Error: Meme library not found at $MEMES_DIR" >&2; exit 1; }
  for dir in "$MEMES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    name=$(basename "$dir"); [[ "$name" == .* || "$name" == hooks ]] && continue
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
    local name=$(basename "$dir"); [[ "$name" == .* || "$name" == hooks ]] && continue
    cats+=("$name")
  done
  [[ ${#cats[@]} -eq 0 ]] && { echo "Error: No categories found" >&2; exit 1; }
  local cat="${cats[$((RANDOM % ${#cats[@]}))]}"
  cmd_pick "$cat"
}

cmd_failures() {
  local tracker_file="$MEMES_DIR/meme-tracker.json"
  command -v jq &>/dev/null || { echo "Error: jq required" >&2; exit 1; }
  [[ -f "$tracker_file" ]] || { echo "No tracker file" >&2; exit 1; }
  local count="${1:-10}"
  local json_mode=false
  [[ "$count" == "--json" ]] && { json_mode=true; count="${2:-10}"; }
  [[ "${2:-}" == "--json" ]] && json_mode=true

  local failures; failures=$(jq --argjson n "$count" '[
    .history[] | select(.result == "failed")
  ] | .[-$n:]' "$tracker_file")

  local total; total=$(jq '[.history[] | select(.result == "failed")] | length' "$tracker_file")

  if $json_mode; then
    echo "$failures"
    return
  fi

  echo "❌ Recent Failures (last $count of $total total)"
  echo "═══════════════════════════════════════════════════"
  echo

  local count_actual; count_actual=$(echo "$failures" | jq 'length')
  if [[ "$count_actual" -eq 0 ]]; then
    echo "No failures recorded! 🎉"
    return
  fi

  echo "$failures" | jq -r '.[] | "\(.time[:19])  \(.category)/\(.file // "?")  [\(.channel // "?")]  \(.error // "(no error captured)")"'
  echo

  # Top failing categories
  echo "📊 Failure hotspots:"
  jq -r '[.history[] | select(.result == "failed") | .category] | group_by(.) | map({cat: .[0], n: length}) | sort_by(-.n) | .[:5][] | "   \(.cat): \(.n) failures"' "$tracker_file"

  # Error pattern summary (if errors are captured)
  local with_errors; with_errors=$(jq '[.history[] | select(.result == "failed" and .error != null and .error != "")] | length' "$tracker_file")
  echo
  echo "📝 Error capture: $with_errors/$total failures have error messages"
}

cmd_stats() {
  local tracker_file="$MEMES_DIR/meme-tracker.json"
  if ! command -v jq &>/dev/null; then
    echo "Error: jq required for stats" >&2; exit 1
  fi
  if [[ ! -f "$tracker_file" ]]; then
    echo "Error: No tracker file at $tracker_file" >&2; exit 1
  fi

  # Use lifetime counters (survive history trimming), fall back to history scan
  local total; total=$(jq '.totalSent // ([.history[] | select(.result != "failed")] | length)' "$tracker_file")
  local failed; failed=$(jq '.totalFailed // ([.history[] | select(.result == "failed")] | length)' "$tracker_file")
  local first_date; first_date=$(jq -r '.history[0].time // "unknown"' "$tracker_file" | cut -c1-10)
  local last_date; last_date=$(jq -r '.history[-1].time // "unknown"' "$tracker_file" | cut -c1-10)
  local trimmed_at; trimmed_at=$(jq -r '.historyTrimmedAt // empty' "$tracker_file" 2>/dev/null)

  echo "=== Meme Stats ==="
  echo "Total sends: $total${failed:+ ($failed failed)}  |  Period: $first_date → $last_date"
  [[ -n "$trimmed_at" ]] && echo "ℹ️  History trimmed (showing last ${MEMES_HISTORY_MAX:-500} entries, lifetime counters preserved)"
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
    local name; name=$(basename "$dir"); [[ "$name" == .* || "$name" == hooks ]] && continue
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

_is_contextual_cat() {
  local cat="$1"
  for ctx in "${MEMES_CONTEXTUAL_CATS[@]}"; do
    [[ "$cat" == "$ctx" ]] && return 0
  done
  return 1
}

_track_send() {
  local category="$1" file="$2" channel="$3" caption="$4" result="${5:-success}" error_msg="${6:-}"
  local tracker_file="$MEMES_DIR/meme-tracker.json"
  command -v jq &>/dev/null || return 0
  local ts; ts=$(date -Iseconds)
  local basename_f; basename_f=$(basename "$file")
  local entry
  if [[ -n "$error_msg" ]]; then
    # Truncate error to 200 chars to keep tracker compact
    error_msg="${error_msg:0:200}"
    entry=$(jq -nc \
      --arg ts "$ts" \
      --arg cat "$category" \
      --arg file "$basename_f" \
      --arg ch "$channel" \
      --arg cap "$caption" \
      --arg res "$result" \
      --arg err "$error_msg" \
      '{time: $ts, action: "send", category: $cat, file: $file, channel: $ch, caption: $cap, result: $res, error: $err, method: "memes send"}')
  else
    entry=$(jq -nc \
      --arg ts "$ts" \
      --arg cat "$category" \
      --arg file "$basename_f" \
      --arg ch "$channel" \
      --arg cap "$caption" \
      --arg res "$result" \
      '{time: $ts, action: "send", category: $cat, file: $file, channel: $ch, caption: $cap, result: $res, method: "memes send"}')
  fi
  local max_history="${MEMES_HISTORY_MAX:-500}"
  if [[ -f "$tracker_file" ]]; then
    local tmp; tmp=$(mktemp)
    # O(1) incremental update: append entry, bump counters, trim if needed
    jq --argjson e "$entry" --arg ts "$ts" --arg res "$result" --arg cat "$category" --argjson max "$max_history" '
      .history += [$e] |
      (if ($res == "success" or $res == "sent") then
        .totalSent = ((.totalSent // 0) + 1) |
        .counts[$cat] = ((.counts[$cat] // 0) + 1)
      else
        .totalFailed = ((.totalFailed // 0) + 1)
      end) |
      .lastUpdated = $ts |
      .consecutiveFailures = (if ($res == "success" or $res == "sent") then 0 else ((.consecutiveFailures // 0) + 1) end) |
      (if (.history | length) > $max then
        .historyTrimmedAt = $ts |
        .history = .history[-$max:]
      else . end)
    ' "$tracker_file" > "$tmp" && mv "$tmp" "$tracker_file"
  else
    local init_sent=0 init_failed=0
    if [[ "$result" == "success" || "$result" == "sent" ]]; then init_sent=1; else init_failed=1; fi
    jq -nc --argjson e "$entry" --arg ts "$ts" --arg cat "$category" --argjson sent "$init_sent" --argjson failed "$init_failed" '
      {history: [$e], totalSent: $sent, totalFailed: $failed, counts: {($cat): $sent}, consecutiveFailures: $failed, lastUpdated: $ts}
    ' > "$tracker_file"
  fi
}

cmd_send() {
  local category="" caption="" to="" channel="${OPENCLAW_CHANNEL:-discord}" account="" file_override=""
  # Detect platform as first arg (overrides env default)
  [[ "${1:-}" =~ ^(discord|feishu|telegram|whatsapp|slack|line|qq|wechat)$ ]] && { channel="$1"; shift; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --category|-c)  category="$2"; shift 2 ;;
      --caption|-m)   caption="$2"; shift 2 ;;
      --to|-t)        to="$2"; shift 2 ;;
      --channel)      channel="$2"; shift 2 ;;
      --account|-a)   account="$2"; shift 2 ;;
      --file|-f)      file_override="$2"; shift 2 ;;
      *)              if [[ -z "$category" ]]; then category="$1"; else caption="${caption:+$caption }$1"; fi; shift ;;
    esac
  done
  [[ -z "$category" ]] && { echo "Usage: memes send <category> [caption] [--to target] [--channel platform] [--file path]" >&2; exit 1; }

  # Resolve alias so tracker records canonical category, not alias
  category=$(_resolve_category "$category")

  local meme_path
  if [[ -n "$file_override" ]]; then
    meme_path="$file_override"
    [[ ! -f "$meme_path" ]] && { echo "Error: file not found: $meme_path" >&2; exit 1; }
  else
    meme_path=$(cmd_pick "$category")
  fi

  # Timeout for send commands (prevents SIGKILL from parent exec timeout)
  local SEND_TIMEOUT="${MEMES_SEND_TIMEOUT:-30}"

  # Capture stderr for error diagnostics on failure
  local _send_err_file; _send_err_file=$(mktemp)
  trap 'rm -f "$_send_err_file"' RETURN 2>/dev/null || true

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
        timeout "$SEND_TIMEOUT" bash "$script" "$target" "$meme_path" "$caption" 2>>"$_send_err_file" || send_rc=$?
      else
        _send_openclaw "$meme_path" "$caption" "channel:$target" "$channel" "$account" 2>>"$_send_err_file" || send_rc=$?
      fi
      ;;
    feishu)
      local script="$SCRIPTS_DIR/feishu-send-image.mjs"
      local target="${to:-${MEMES_CURRENT_TARGET:-${MEMES_DEFAULT_FEISHU:-}}}"
      [[ -z "$target" ]] && { echo "Error: --to <target> required (or set MEMES_DEFAULT_FEISHU)" >&2; exit 1; }
      if [[ -f "$script" ]]; then
        timeout "$SEND_TIMEOUT" node "$script" "$target" "$meme_path" ${caption:+"$caption"} 2>>"$_send_err_file" || send_rc=$?
      else
        _send_openclaw "$meme_path" "$caption" "$to" "feishu" "$account" 2>>"$_send_err_file" || send_rc=$?
      fi
      ;;
    line)
      local script="$SCRIPTS_DIR/line-send-image.sh"
      local target="${to:-${MEMES_CURRENT_TARGET:-${MEMES_DEFAULT_LINE:-}}}"
      [[ -z "$target" ]] && { echo "Error: --to <user_or_group_id> required (or set MEMES_DEFAULT_LINE)" >&2; exit 1; }
      if [[ -x "$script" ]]; then
        timeout "$SEND_TIMEOUT" bash "$script" "$target" "$meme_path" "$caption" 2>>"$_send_err_file" || send_rc=$?
      else
        _send_openclaw "$meme_path" "$caption" "$to" "line" "$account" 2>>"$_send_err_file" || send_rc=$?
      fi
      ;;
    telegram)
      local script="$SCRIPTS_DIR/telegram-send-image.sh"
      local target="${to:-${MEMES_CURRENT_TARGET:-${MEMES_DEFAULT_TELEGRAM:-}}}"
      [[ -z "$target" ]] && { echo "Error: --to <chat_id> required (or set MEMES_DEFAULT_TELEGRAM)" >&2; exit 1; }
      if [[ -x "$script" ]]; then
        timeout "$SEND_TIMEOUT" bash "$script" "$target" "$meme_path" "$caption" 2>>"$_send_err_file" || send_rc=$?
      else
        _send_openclaw "$meme_path" "$caption" "$to" "telegram" "$account" 2>>"$_send_err_file" || send_rc=$?
      fi
      ;;
    *)
      local script="$SCRIPTS_DIR/${channel}-send-image.sh"
      if [[ -x "$script" ]]; then
        timeout "$SEND_TIMEOUT" bash "$script" "${to:-}" "$meme_path" "$caption" 2>>"$_send_err_file" || send_rc=$?
      else
        _send_openclaw "$meme_path" "$caption" "$to" "$channel" "$account" 2>>"$_send_err_file" || send_rc=$?
      fi
      ;;
  esac

  # Auto-retry with a different file on failure (once)
  if [[ $send_rc -ne 0 ]]; then
    # Extract meaningful error: take last non-whitespace line (actual error, not CLI noise)
    local _send_err; _send_err=$(grep -v -E '^[[:space:]]*$' "$_send_err_file" 2>/dev/null | tail -1 | head -c 200)
    _track_send "$category" "$meme_path" "$channel" "$caption" "failed" "$_send_err"
    echo "[memes] send failed (rc=$send_rc) for $(basename "$meme_path")${_send_err:+: $_send_err}, retrying with another file..." >&2
    > "$_send_err_file"  # reset for retry
    local retry_path; retry_path=$(MEMES_EXCLUDE_FILE="$(basename "$meme_path")" cmd_pick "$category" 2>/dev/null || true)
    if [[ -n "$retry_path" && "$retry_path" != "$meme_path" ]]; then
      local retry_rc=0
      case "$channel" in
        discord)
          local r_target="${to#channel:}"
          [[ -z "$r_target" ]] && r_target="${MEMES_CURRENT_TARGET:-${MEMES_DEFAULT_CHANNEL:-}}"
          if [[ -x "$SCRIPTS_DIR/discord-send-image.sh" ]]; then
            timeout "$SEND_TIMEOUT" bash "$SCRIPTS_DIR/discord-send-image.sh" "$r_target" "$retry_path" "$caption" 2>>"$_send_err_file" || retry_rc=$?
          else
            _send_openclaw "$retry_path" "$caption" "channel:$r_target" "$channel" "$account" 2>>"$_send_err_file" || retry_rc=$?
          fi
          ;;
        *) _send_openclaw "$retry_path" "$caption" "$to" "$channel" "$account" 2>>"$_send_err_file" || retry_rc=$? ;;
      esac
      local retry_result="success"
      [[ $retry_rc -ne 0 ]] && retry_result="failed"
      local _retry_err=""
      [[ "$retry_result" == "failed" ]] && _retry_err=$(grep -v -E "^[[:space:]]*\$" "$_send_err_file" 2>/dev/null | tail -1 | head -c 200)
      _track_send "$category" "$retry_path" "$channel" "$caption" "$retry_result" "$_retry_err"
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
  timeout "$send_timeout" bash -c "$cmd"
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

cmd_suggest() {
  local json_mode=false send_mode=false
  local send_to="" send_channel="" send_caption=""
  local -a input_parts=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)    json_mode=true; shift ;;
      --send)    send_mode=true; shift ;;
      --to)      send_to="$2"; shift 2 ;;
      --channel) send_channel="$2"; shift 2 ;;
      --caption) send_caption="$2"; shift 2 ;;
      *)         input_parts+=("$1"); shift ;;
    esac
  done
  local input="${input_parts[*]:-}"
  [[ -z "$input" ]] && { echo "Usage: memes suggest <text or mood> [--send] [--to TARGET] [--channel PLATFORM] [--caption TEXT]" >&2; echo "Examples:" >&2; echo "  memes suggest tired after debugging all day" >&2; echo "  memes suggest great job well done" >&2; echo "  memes suggest 好无语" >&2; echo "  memes suggest waiting for CI" >&2; echo "  memes suggest happy --send --to channel:123" >&2; exit 1; }
  local tags_file="$MEMES_DIR/tags.json"
  if ! command -v jq &>/dev/null; then
    echo "Error: jq required for suggest" >&2; exit 1
  fi
  [[ ! -f "$tags_file" ]] && { echo "Error: No tags.json at $tags_file" >&2; exit 1; }

  # Synonym map: natural language → tag-relevant keywords
  # Each entry: "input_word:tag1,tag2,tag3"
  local -a synonyms=(
    # Tiredness / exhaustion
    "tired:tired,exhausted,sleepy,done,dead,burnout"
    "exhausted:tired,exhausted,sleepy,done,dead"
    "sleepy:tired,sleepy,bedtime,yawn"
    "累:tired,exhausted,sleepy,dead"
    "困:tired,sleepy,bedtime,yawn"
    # Happiness / celebration
    "happy:happy,joy,excited,celebration,yay"
    "great:great-job,well-done,approval,celebration,nailed-it"
    "nice:approval,great-job,well-done,thumbs-up"
    "awesome:celebration,nailed-it,excited,wow"
    "yay:celebration,happy,excited,joy"
    "开心:happy,joy,excited,celebration"
    "棒:great-job,well-done,approval,celebration"
    # Sadness
    "sad:sad,crying,disappointed,heartbroken"
    "crying:crying,sad,tears,emotional"
    "难过:sad,crying,disappointed"
    "伤心:sad,crying,heartbroken"
    # Frustration / facepalm
    "frustrated:frustrated,facepalm,annoyed,ugh"
    "facepalm:facepalm,cringe,fail,disappointed"
    "ugh:facepalm,annoyed,frustrated,cringe"
    "无语:facepalm,cringe,speechless,bruh"
    "服了:facepalm,surrender,cringe,bruh"
    # Confusion
    "confused:confused,bewildered,thinking,huh"
    "what:confused,bewildered,huh,shocked"
    "huh:confused,bewildered,huh,surprised"
    "懵:confused,bewildered,thinking"
    # Working / busy
    "working:working,busy,coding,focus,hustle"
    "coding:coding,working,typing,focus,debug"
    "busy:busy,working,hustle,focus"
    "debug:debug,coding,bug,frustration,working"
    "debugging:debug,coding,bug,frustration"
    # Waiting
    "waiting:waiting,bored,anticipation,patience"
    "等:waiting,bored,anticipation"
    # Panic / emergency
    "panic:panic,fire,emergency,chaos,alarm"
    "help:panic,emergency,chaos,alarm"
    "fire:fire,panic,emergency,burning,chaos"
    "救:panic,emergency,alarm"
    # Love / affection
    "love:love,heart,adore,affection,care"
    "cute:cute,adorable,aww,fluffy"
    "爱:love,heart,adore,affection"
    "可爱:cute,adorable,aww,fluffy"
    # Approval / agreement
    "approve:approval,agree,yes,thumbs-up,ok"
    "agree:agree,approval,nodding,yes"
    "yes:yes,approval,agree,thumbs-up"
    "好:approval,agree,thumbs-up,ok"
    # Disapproval / disappointment
    "disappointed:disappointed,letdown,sad,sigh"
    "nope:disagree,nope,no,shrug,disappointed"
    "失望:disappointed,letdown,sad,sigh"
    # Wow / surprise
    "wow:wow,amazed,surprised,shocked,impressed"
    "amazing:wow,amazed,impressed,incredible"
    "卧槽:wow,amazed,shocked,surprised"
    "厉害:wow,impressed,amazed,incredible"
    # Thinking
    "thinking:thinking,calculating,pondering,hmm"
    "hmm:thinking,pondering,calculating,hmm"
    "想:thinking,pondering,calculating"
    # Thanks
    "thanks:thanks,grateful,appreciate,thank-you"
    "thank:thanks,grateful,appreciate,thank-you"
    "谢:thanks,grateful,appreciate"
    # Greeting
    "morning:morning,sunrise,wake-up,hello"
    "night:night,bedtime,sleepy,bye"
    "hello:hello,greeting,wave,hi"
    "bye:bye,farewell,wave,see-you"
    "早:morning,sunrise,wake-up"
    "晚安:night,bedtime,sleepy"
    # Shrug / idk
    "shrug:shrug,idk,whatever,beats-me"
    "idk:shrug,idk,whatever,dunno"
    "whatever:shrug,whatever,idk,meh"
    "随便:shrug,whatever,idk"
    # Smug
    "smug:smug,smirk,confident,sly"
    "得意:smug,smirk,confident"
    # Encouragement
    "encourage:encourage,motivate,believe,cheer"
    "加油:encourage,motivate,believe,fight"
    "fighting:encourage,fight,motivate,believe"
    # Bruh
    "bruh:bruh,really,seriously,deadpan"
    "seriously:bruh,really,seriously,deadpan"
    "真的:bruh,really,seriously"
    # Popcorn / watching
    "popcorn:popcorn,watching,drama,observer"
    "drama:popcorn,watching,drama,observer"
    "吃瓜:popcorn,watching,drama,observer"
    # Chinese internet slang (extended)
    "尴尬:facepalm,cringe,awkward,embarrassed"
    "社死:facepalm,panic,cringe,embarrassed"
    "摆烂:shrug,tired,done,whatever,meh"
    "躺平:shrug,tired,done,whatever"
    "破防:sad,crying,shocked,emotional"
    "绝了:wow,amazed,bruh,incredible"
    "离谱:wow,bruh,facepalm,shocked"
    "有道理:thinking,approve,agree,nodding"
    "好奇:thinking,confused,curious,pondering"
    "笑死:happy,joy,excited,lol"
    "崩溃:panic,tired,sad,frustrated"
    "牛:wow,nailed-it,impressed,approve"
    "啊这:confused,bruh,awkward,huh"
    "无所谓:shrug,whatever,idk,meh"
    "蚌埠住了:happy,bruh,joy,lol"
    "emo:sad,crying,emotional,disappointed"
  )

  # 1. Lowercase + tokenize input
  local lower_input; lower_input=$(echo "$input" | tr '[:upper:]' '[:lower:]')
  local -a raw_words=()
  for word in $lower_input; do
    raw_words+=("$word")
  done

  # 2. Expand via synonym map
  local -a expanded_words=()
  for word in "${raw_words[@]}"; do
    local matched=false
    for syn in "${synonyms[@]}"; do
      local key="${syn%%:*}"
      local vals="${syn#*:}"
      if [[ "$word" == *"$key"* ]]; then
        IFS=',' read -ra tags <<< "$vals"
        for t in "${tags[@]}"; do
          expanded_words+=("$t")
        done
        matched=true
      fi
    done
    # Always include the raw word too
    expanded_words+=("$word")
  done

  # 3. Deduplicate
  local -A seen_words
  local -a search_words=()
  for w in "${expanded_words[@]}"; do
    if [[ -z "${seen_words[$w]:-}" ]]; then
      seen_words[$w]=1
      search_words+=("$w")
    fi
  done

  # 4. Build category list for boost
  local -a categories=()
  for dir in "$MEMES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local cat; cat=$(basename "$dir")
    [[ "$cat" == .* || "$cat" == hooks ]] && continue
    categories+=("$cat")
  done

  # 5. Score via jq: tag matches + category-name bonus
  local words_str="${search_words[*]}"
  local cats_str; cats_str=$(printf '%s\n' "${categories[@]}" | paste -sd' ')
  local raw_str="${raw_words[*]}"

  local results; results=$(jq -r \
    --arg words "$words_str" \
    --arg raw "$raw_str" '
    ($words | split(" ")) as $ws |
    ($raw | split(" ")) as $rw |
    to_entries
    | map(select(.key != "_meta" and .key != "_styles" and (.key | contains("/")) and (.value | type == "array")))
    | map({
        file: .key,
        cat: (.key | split("/")[0]),
        tags: [.value[] | select(type=="string")],
        matched_tags: [.value[] | select(type=="string") | . as $tag | if [$ws[] | . as $w | select($tag | test($w; "i"))] | length > 0 then $tag else empty end] | unique | length,
        cat_boost: ((.key | split("/")[0]) as $c | if [$rw[] | . as $w | select($c | test($w; "i"))] | length > 0 then 2 else 0 end)
      })
    | map(.score = .matched_tags + .cat_boost)
    | map(select(.score > 0))
    | sort_by(-.score, .file)
    | .[:3]
    | .[] | "\(.score)\t\(.cat)\t\(.file)\t\(.tags | join(", "))"
  ' "$tags_file" 2>/dev/null)

  if [[ -z "$results" ]]; then
    if $json_mode; then
      echo '[]'
    else
      echo "No meme suggestions for: $input" >&2
      echo "Tip: try simpler mood words (happy, sad, tired, confused, wow)" >&2
    fi
    return 1
  fi

  if $json_mode; then
    echo "$results" | jq -Rsc '
      split("\n") | map(select(length > 0)) | map(
        split("\t") | {score: (.[0] | tonumber), category: .[1], file: .[2], path: ("'"$MEMES_DIR"'/" + .[2]), tags: (.[3] | split(", "))}
      )
    '
    return 0
  fi

  echo "💡 Meme suggestions for: \"$input\""
  echo ""
  local rank=0
  echo "$results" | while IFS=$'\t' read -r score cat file tags; do
    rank=$((rank + 1))
    local full_path="$MEMES_DIR/$file"
    echo "  $rank. [$cat] $(basename "$file")"
    echo "     Path: $full_path"
    echo "     Tags: $tags"
    echo "     Score: $score"
    echo ""
  done

  # Auto-send if --send flag
  if $send_mode; then
    local top_file; top_file=$(echo "$results" | head -1 | cut -f3)
    local top_cat; top_cat=$(echo "$results" | head -1 | cut -f2)
    local full_path="$MEMES_DIR/$top_file"
    echo "🚀 Auto-sending: [$top_cat] $(basename "$top_file")"
    local -a send_args=("$top_cat" "--file" "$full_path")
    [[ -n "$send_caption" ]] && send_args+=("$send_caption")
    [[ -n "$send_to" ]]      && send_args+=("--to" "$send_to")
    [[ -n "$send_channel" ]]  && send_args+=("--channel" "$send_channel")
    cmd_send "${send_args[@]}"
    return $?
  fi

  # Show quick-send hint
  local top_cat; top_cat=$(echo "$results" | head -1 | cut -f2)
  echo "Quick send: memes send $top_cat"
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
    [[ "$name" == .* || "$name" == hooks ]] && continue
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
      [[ "$name" == .* || "$name" == hooks ]] && continue
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

cmd_freshness() {
  # Show per-category last-used time + staleness ranking
  # Flags categories unused >7 days as candidates for `memes wake`
  local json_mode=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json_mode=true; shift ;;
      *) shift ;;
    esac
  done

  local tracker_file="$MEMES_DIR/meme-tracker.json"
  if ! command -v jq &>/dev/null; then
    echo "Error: jq required for freshness" >&2; exit 1
  fi
  if [[ ! -f "$tracker_file" ]]; then
    echo "Error: No tracker file at $tracker_file" >&2; exit 1
  fi

  local now_epoch; now_epoch=$(date +%s)
  local stale_threshold=$((7 * 86400))  # 7 days in seconds
  local contextual_threshold=$((14 * 86400))  # 14 days for contextual categories
  local today; today=$(date +%Y-%m-%d)

  # Build list of all categories from directories
  local -a all_cats=()
  for dir in "$MEMES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local name; name=$(basename "$dir")
    [[ "$name" == .* || "$name" == hooks ]] && continue
    all_cats+=("$name")
  done

  # For each category, find last successful send time
  local -a entries=()  # "epoch|iso_time|category" sorted by staleness
  local stale_count=0
  local gen_stale_count=0
  local ctx_stale_count=0
  for cat in "${all_cats[@]}"; do
    local last_send
    last_send=$(jq -r --arg cat "$cat" '
      [.history[] | select(.category == $cat and (.result == "success" or .result == "sent")) | .time]
      | last // ""' "$tracker_file" 2>/dev/null)
    if [[ -z "$last_send" || "$last_send" == "null" ]]; then
      entries+=("0|never|$cat")
      stale_count=$((stale_count + 1))
      if _is_contextual_cat "$cat"; then
        ctx_stale_count=$((ctx_stale_count + 1))
      else
        gen_stale_count=$((gen_stale_count + 1))
      fi
    else
      # Parse ISO time to epoch for staleness calculation
      local send_epoch
      send_epoch=$(date -d "$last_send" +%s 2>/dev/null || echo 0)
      local age_s=$((now_epoch - send_epoch))
      local cat_threshold=$stale_threshold
      _is_contextual_cat "$cat" && cat_threshold=$contextual_threshold
      if [[ $age_s -gt $cat_threshold ]]; then
        stale_count=$((stale_count + 1))
        if _is_contextual_cat "$cat"; then
          ctx_stale_count=$((ctx_stale_count + 1))
        else
          gen_stale_count=$((gen_stale_count + 1))
        fi
      fi
      entries+=("$send_epoch|$last_send|$cat")
    fi
  done

  # Sort entries by epoch ascending (oldest/stalest first)
  IFS=$'\n' sorted=($(printf '%s\n' "${entries[@]}" | sort -t'|' -k1,1n)); unset IFS

  if $json_mode; then
    # Output JSON array sorted by staleness (most stale first)
    local json_arr=""
    for entry in "${sorted[@]}"; do
      local ep="${entry%%|*}"
      local rest="${entry#*|}"
      local ts="${rest%%|*}"
      local cat="${rest#*|}"
      local age_days="null" stale="true"
      if [[ "$ep" -gt 0 ]]; then
        local age_s=$((now_epoch - ep))
        age_days=$(awk "BEGIN {printf \"%.1f\", $age_s / 86400}")
        local jcat_threshold=$stale_threshold
        _is_contextual_cat "$cat" && jcat_threshold=$contextual_threshold
        [[ $age_s -le $jcat_threshold ]] && stale="false"
      fi
      local contextual=false
      _is_contextual_cat "$cat" && contextual=true
      local item; item=$(jq -n \
        --arg cat "$cat" \
        --arg lastSend "$ts" \
        --argjson ageDays "$age_days" \
        --argjson stale "$stale" \
        --argjson contextual "$contextual" \
        '{category:$cat, lastSend:$lastSend, ageDays:$ageDays, stale:$stale, contextual:$contextual}')
      [[ -n "$json_arr" ]] && json_arr+=","
      json_arr+="$item"
    done
    jq -n --argjson cats "[$json_arr]" --argjson staleCount "$stale_count" --argjson total "${#all_cats[@]}" \
      '{categories:$cats, staleCount:$staleCount, total:$total, thresholdDays:7, contextualThresholdDays:14}'
    return 0
  fi

  # Table output
  echo "🕐 Meme Freshness Report"
  echo "========================"
  echo ""
  printf "%-23s %-20s %8s  %s\n" "Category" "Last Used" "Age" "Status"
  printf '%0.s─' {1..70}; echo ""

  for entry in "${sorted[@]}"; do
    local ep="${entry%%|*}"
    local rest="${entry#*|}"
    local ts="${rest%%|*}"
    local cat="${rest#*|}"

    local age_str="" status=""
    if [[ "$ep" -eq 0 ]]; then
      age_str="  ∞"
      status="🚨 NEVER SENT"
    else
      local age_s=$((now_epoch - ep))
      local age_d=$((age_s / 86400))
      local age_h=$(( (age_s % 86400) / 3600 ))
      if [[ $age_d -gt 0 ]]; then
        age_str="${age_d}d ${age_h}h"
      else
        age_str="${age_h}h"
      fi
      local tbl_threshold=$stale_threshold
      local ctx_label=""
      if _is_contextual_cat "$cat"; then
        tbl_threshold=$contextual_threshold
        ctx_label=" (ctx)"
      fi
      if [[ $age_s -gt $tbl_threshold ]]; then
        status="⚠️  STALE${ctx_label}"
      elif [[ $age_s -gt $((3 * 86400)) ]]; then
        status="💤 aging"
      else
        status="✅ fresh"
      fi
    fi

    local display_ts="$ts"
    [[ "$ts" != "never" ]] && display_ts=$(echo "$ts" | cut -c1-16)

    printf "%-23s %-20s %8s  %s\n" "$cat" "$display_ts" "$age_str" "$status"
  done

  echo ""
  printf '%0.s─' {1..70}; echo ""
  if [[ "$stale_count" -gt 0 ]]; then
    echo "Total: ${#all_cats[@]} categories | Stale: $stale_count ($gen_stale_count general + $ctx_stale_count contextual)"
  else
    echo "Total: ${#all_cats[@]} categories | Stale: $stale_count"
  fi

  if [[ $stale_count -gt 0 ]]; then
    echo ""
    echo "💡 Wake stale categories with: memes wake --send"
    echo "   Or blast multiple: memes dormant-blast $stale_count --to <target>"
  fi
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
    [[ "$name" == .* || "$name" == hooks ]] && continue
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
      [[ "$name" == .* || "$name" == hooks ]] && continue
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
    all_cats_json=$(for dir in "$MEMES_DIR"/*/; do [[ -d "$dir" ]] && basename "$dir"; done | grep -v '^\.\|^hooks$\|^$' | jq -R -s 'split("\n") | map(select(length > 0))')
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
    [[ "$name" == .* || "$name" == hooks ]] && continue
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

  if [[ "$do_send" == true ]]; then
    echo "💤 Waking dormant category: $most_dormant (last send: ${oldest_time:-never})" >&2
    # Auto-send to channel
    local caption="${send_caption:-💤 meme of the day — waking $most_dormant}"
    local -a send_args=("$most_dormant" "$caption")
    [[ -n "$send_to" ]] && send_args+=("--to" "$send_to")
    [[ -n "$send_channel" ]] && send_args+=("--channel" "$send_channel")
    cmd_send "${send_args[@]}"
  else
    echo "🎲 Picked from $most_dormant (last send: ${oldest_time:-never}) — use --send to deliver" >&2
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
    [[ "$name" == .* || "$name" == hooks ]] && continue
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
    [[ "$name" == .* || "$name" == hooks ]] && continue
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

# --- lint command: check & auto-fix untagged/unstyled files ---
# Category name → default base tags mapping
_category_default_tags() {
  local cat="$1"
  case "$cat" in
    approve)          echo '["approval","well-done","great-job"]' ;;
    bruh)             echo '["bruh","disbelief","wtf"]' ;;
    confused)         echo '["confused","huh","bewildered"]' ;;
    cute-animals)     echo '["cute","animal","adorable"]' ;;
    debug-mood)       echo '["debug","coding","error"]' ;;
    disappointed)     echo '["disappointed","disapproval","no"]' ;;
    encourage)        echo '["encourage","cheer","motivation"]' ;;
    facepalm)         echo '["facepalm","disapprove","cringe"]' ;;
    greeting-bye)     echo '["greeting","bye","farewell"]' ;;
    greeting-hello)   echo '["greeting","hello","hi","wave"]' ;;
    greeting-morning) echo '["greeting","morning","waking-up"]' ;;
    greeting-night)   echo '["greeting","night","sleep","cozy"]' ;;
    happy)            echo '["happy","joy","cheerful"]' ;;
    love)             echo '["love","heart","affection"]' ;;
    nailed-it)        echo '["nailed-it","success","victory"]' ;;
    panic)            echo '["panic","alarm","emergency"]' ;;
    popcorn)          echo '["popcorn","watching","drama"]' ;;
    sad)              echo '["sad","crying","upset"]' ;;
    shrug)            echo '["shrug","helpless","dunno"]' ;;
    smug)             echo '["smug","smirk","confident"]' ;;
    thanks)           echo '["thanks","grateful","appreciation"]' ;;
    thinking)         echo '["thinking","pondering","hmm"]' ;;
    tired)            echo '["tired","sleepy","exhausted"]' ;;
    waiting)          echo '["waiting","impatient","bored"]' ;;
    working)          echo '["working","busy","focused"]' ;;
    wow)              echo '["wow","surprised","shocked"]' ;;
    *)                echo "[\"${cat}\"]" ;;
  esac
}

# Guess style from filename keywords or extension
_guess_style() {
  local fname="$1"
  local lower
  lower=$(echo "$fname" | tr '[:upper:]' '[:lower:]')
  # Keyword-based guessing
  case "$lower" in
    *anime*|*manga*|*waifu*|*chibi*|*kawaii*) echo "anime"; return ;;
    *cat-*|*dog-*|*bunny*|*kitten*|*puppy*|*hamster*|*bird*|*panda*|*duck*|*snoopy*) echo "animal"; return ;;
    *cartoon*|*simpsons*|*spongebob*|*tom-*|*jerry*|*bugs-bunny*) echo "cartoon"; return ;;
    *irl-*|*real-*|*photo-*|*live-*) echo "live-action"; return ;;
  esac
  # Default
  echo "meme"
}

cmd_lint() {
  local fix=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fix) fix=true; shift ;;
      *) echo "Unknown lint option: $1" >&2; return 1 ;;
    esac
  done

  local tag_file="$MEMES_DIR/tags.json"
  if [[ ! -f "$tag_file" ]]; then
    echo "❌ tags.json not found at $tag_file"
    return 1
  fi

  local all_files
  all_files=$(cd "$MEMES_DIR" && find . -maxdepth 2 -type f \( -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.webp' \) | sed 's|^\./||' | sort)

  # Collect untagged and unstyled files
  local untagged=() unstyled=()
  while IFS= read -r f; do
    local has_tag
    has_tag=$(jq -r --arg k "$f" 'has($k)' "$tag_file" 2>/dev/null || echo "false")
    [[ "$has_tag" != "true" ]] && untagged+=("$f")

    local has_style
    has_style=$(jq -r --arg k "$f" '._styles | has($k)' "$tag_file" 2>/dev/null || echo "false")
    [[ "$has_style" != "true" ]] && unstyled+=("$f")
  done <<< "$all_files"

  echo "🔎 Meme Lint"
  echo "============"

  local total_fixed=0

  # Report & optionally fix untagged
  if [[ ${#untagged[@]} -gt 0 ]]; then
    echo ""
    echo "## Untagged files (${#untagged[@]})"
    for f in "${untagged[@]}"; do
      local cat
      cat=$(dirname "$f")
      local base
      base=$(basename "$f" | sed 's/\.[^.]*$//')
      local default_tags
      default_tags=$(_category_default_tags "$cat")
      # Add filename-derived tag if descriptive enough (>2 chars, not generic)
      local name_tag
      name_tag=$(echo "$base" | tr '[:upper:]_' '[:lower:]-' | sed 's/[^a-z0-9-]//g')
      if [[ ${#name_tag} -gt 2 ]] && ! echo "$default_tags" | grep -q "\"$name_tag\""; then
        default_tags=$(echo "$default_tags" | sed "s/]$/,\"$name_tag\"]/")
      fi
      if [[ "$fix" == true ]]; then
        # Add to tags.json
        local tmp
        tmp=$(mktemp)
        jq --arg k "$f" --argjson v "$default_tags" '. + {($k): $v}' "$tag_file" > "$tmp" && mv "$tmp" "$tag_file"
        echo "  ✅ $f → tagged: $default_tags"
        total_fixed=$((total_fixed + 1))
      else
        echo "  ⚠️  $f — would add: $default_tags"
      fi
    done
  else
    echo ""
    echo "## Untagged files"
    echo "  ✅ All files tagged"
  fi

  # Report & optionally fix unstyled (re-check after tag fix since we modify same file)
  if [[ ${#unstyled[@]} -gt 0 ]]; then
    echo ""
    echo "## Unstyled files (${#unstyled[@]})"
    for f in "${unstyled[@]}"; do
      local style
      style=$(_guess_style "$(basename "$f")")
      if [[ "$fix" == true ]]; then
        local tmp
        tmp=$(mktemp)
        jq --arg k "$f" --arg v "$style" '._styles += {($k): $v}' "$tag_file" > "$tmp" && mv "$tmp" "$tag_file"
        echo "  ✅ $f → style: $style"
        total_fixed=$((total_fixed + 1))
      else
        echo "  ⚠️  $f — would add style: $style"
      fi
    done
  else
    echo ""
    echo "## Unstyled files"
    echo "  ✅ All files styled"
  fi

  echo ""
  echo "============"
  if [[ "$fix" == true && $total_fixed -gt 0 ]]; then
    echo "✅ Fixed $total_fixed issue(s)"
  elif [[ ${#untagged[@]} -eq 0 && ${#unstyled[@]} -eq 0 ]]; then
    echo "✅ Lint passed — all files tagged and styled"
  else
    echo "⚠️  $(( ${#untagged[@]} + ${#unstyled[@]} )) issue(s) found — run 'memes lint --fix' to auto-fix"
    return 1
  fi
}

cmd_coverage() {
  # Show tag/style coverage %, avg tag depth, and style diversity per category
  # Identifies weakest categories needing attention
  # --json: output machine-readable JSON instead of table
  # --json --weak: JSON filtered to only categories with issues (for CI/alerting)
  local json_mode=false
  local weak_only=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json_mode=true ;;
      --weak) weak_only=true ;;
    esac
    shift
  done

  local tag_file="$MEMES_DIR/tags.json"
  if [[ ! -f "$tag_file" ]] || ! command -v jq &>/dev/null; then
    if $json_mode; then
      echo '{"error":"Requires tags.json and jq"}'
    else
      echo "❌ Requires tags.json and jq" >&2
    fi
    return 1
  fi

  local total_files=0 total_tagged=0 total_styled=0
  local -a weak_cats=()
  local json_cats=""

  $json_mode || {
    echo "📊 Meme Coverage Report"
    echo "======================="
    echo ""
    printf "%-20s %5s %6s %5s %6s %5s %7s %8s\n" "Category" "Files" "Tagged" "Tag%" "Styled" "Sty%" "AvgTags" "Styles"
    printf '%0.s─' {1..80}; echo ""
  }

  for dir in "$MEMES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local name; name=$(basename "$dir")
    [[ "$name" == .* || "$name" == hooks ]] && continue

    local files; files=$(find "$dir" -maxdepth 1 -type f \( -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.webp' \) -printf '%f\n')
    local count=0 tagged=0 styled=0 tag_sum=0
    local -A style_set=()
    local -a style_names=()

    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      count=$((count + 1))
      local key="$name/$f"

      # Check tags
      local ntags; ntags=$(jq -r --arg k "$key" 'if .[$k] then (.[$k] | length) else 0 end' "$tag_file" 2>/dev/null)
      if [[ "$ntags" -gt 0 ]]; then
        tagged=$((tagged + 1))
        tag_sum=$((tag_sum + ntags))
      fi

      # Check style
      local style; style=$(jq -r --arg k "$key" '._styles[$k] // empty' "$tag_file" 2>/dev/null)
      if [[ -n "$style" ]]; then
        styled=$((styled + 1))
        if [[ -z "${style_set[$style]+_}" ]]; then
          style_set["$style"]=1
          style_names+=("$style")
        fi
      fi
    done <<< "$files"

    [[ $count -eq 0 ]] && continue

    local tag_pct=$((tagged * 100 / count))
    local sty_pct=$((styled * 100 / count))
    local avg_tags="0.0"
    if [[ $tagged -gt 0 ]]; then
      avg_tags=$(awk "BEGIN {printf \"%.1f\", $tag_sum / $tagged}")
    fi
    local style_div=${#style_set[@]}

    $json_mode || printf "%-20s %5d %6d %4d%% %6d %4d%% %7s %8d\n" \
      "$name" "$count" "$tagged" "$tag_pct" "$styled" "$sty_pct" "$avg_tags" "$style_div"

    total_files=$((total_files + count))
    total_tagged=$((total_tagged + tagged))
    total_styled=$((total_styled + styled))

    # Flag weakness
    local -a issue_list=()
    if [[ $tag_pct -lt 100 ]]; then issue_list+=("tags_${tag_pct}pct"); fi
    if [[ $sty_pct -lt 100 ]]; then issue_list+=("styles_${sty_pct}pct"); fi
    if [[ $(awk "BEGIN {print ($tag_sum / ($tagged > 0 ? $tagged : 1) < 4) ? 1 : 0}") -eq 1 && $tagged -gt 0 ]]; then
      issue_list+=("shallow_tags")
    fi
    if [[ $style_div -lt 2 ]]; then
      issue_list+=("low_style_diversity")
    fi

    # Human-readable weakness
    local issues=""
    if [[ $tag_pct -lt 100 ]]; then issues+="tags ${tag_pct}%"; fi
    if [[ $sty_pct -lt 100 ]]; then [[ -n "$issues" ]] && issues+=" | "; issues+="styles ${sty_pct}%"; fi
    if [[ $(awk "BEGIN {print ($tag_sum / ($tagged > 0 ? $tagged : 1) < 4) ? 1 : 0}") -eq 1 && $tagged -gt 0 ]]; then
      [[ -n "$issues" ]] && issues+=" | "; issues+="shallow tags ($avg_tags avg)"
    fi
    if [[ $style_div -lt 2 ]]; then
      [[ -n "$issues" ]] && issues+=" | "; issues+="low style diversity ($style_div)"
    fi
    [[ -n "$issues" ]] && weak_cats+=("$name: $issues")

    # Build JSON category entry
    if $json_mode; then
      local styles_json="[]"
      if [[ ${#style_names[@]} -gt 0 ]]; then
        styles_json=$(printf '%s\n' "${style_names[@]}" | jq -R . | jq -s .)
      fi
      local issues_json="[]"
      if [[ ${#issue_list[@]} -gt 0 ]]; then
        issues_json=$(printf '%s\n' "${issue_list[@]}" | jq -R . | jq -s .)
      fi
      local cat_json; cat_json=$(jq -n \
        --arg name "$name" \
        --argjson files "$count" \
        --argjson tagged "$tagged" \
        --argjson tagPct "$tag_pct" \
        --argjson styled "$styled" \
        --argjson styPct "$sty_pct" \
        --arg avgTags "$avg_tags" \
        --argjson styleDiversity "$style_div" \
        --argjson styles "$styles_json" \
        --argjson issues "$issues_json" \
        '{name:$name, files:$files, tagged:$tagged, tagPct:$tagPct, styled:$styled, styPct:$styPct, avgTags:($avgTags|tonumber), styleDiversity:$styleDiversity, styles:$styles, issues:$issues}')
      [[ -n "$json_cats" ]] && json_cats+=","
      json_cats+="$cat_json"
    fi
  done

  if $json_mode; then
    local total_tag_pct=0 total_sty_pct=0
    [[ $total_files -gt 0 ]] && total_tag_pct=$((total_tagged * 100 / total_files))
    [[ $total_files -gt 0 ]] && total_sty_pct=$((total_styled * 100 / total_files))
    local full_json; full_json=$(jq -n \
      --argjson categories "[$json_cats]" \
      --argjson totalFiles "$total_files" \
      --argjson totalTagged "$total_tagged" \
      --argjson totalTagPct "$total_tag_pct" \
      --argjson totalStyled "$total_styled" \
      --argjson totalStyPct "$total_sty_pct" \
      '{categories:$categories, totals:{files:$totalFiles, tagged:$totalTagged, tagPct:$totalTagPct, styled:$totalStyled, styPct:$totalStyPct}}')

    if $weak_only; then
      echo "$full_json" | jq '{categories: [.categories[] | select(.issues | length > 0)], totals: .totals}'
    else
      echo "$full_json"
    fi
    return 0
  fi

  printf '%0.s─' {1..80}; echo ""
  # Totals
  local total_tag_pct=0 total_sty_pct=0
  [[ $total_files -gt 0 ]] && total_tag_pct=$((total_tagged * 100 / total_files))
  [[ $total_files -gt 0 ]] && total_sty_pct=$((total_styled * 100 / total_files))
  printf "%-20s %5d %6d %4d%% %6d %4d%%\n" "TOTAL" "$total_files" "$total_tagged" "$total_tag_pct" "$total_styled" "$total_sty_pct"
  echo ""

  # Weakest categories
  if [[ ${#weak_cats[@]} -gt 0 ]]; then
    echo "⚠️  Weakest categories:"
    for entry in "${weak_cats[@]}"; do
      echo "  → $entry"
    done
  else
    echo "✅ All categories have excellent coverage!"
  fi
}

cmd_review() {
  # Cron-friendly review check: runs coverage, logs to tracker, reports weak areas
  # Used by memes-review cron to auto-detect and surface quality issues
  # --full: include health + audit summary for comprehensive single-command cron check
  local full_mode=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --full) full_mode=true; shift ;;
      *) shift ;;
    esac
  done

  local tracker="$MEMES_DIR/meme-tracker.json"
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  echo "🔍 Memes Review — Coverage Check"
  echo "================================="
  echo ""

  # Run coverage --json --weak
  local weak_json; weak_json=$(cmd_coverage --json --weak 2>/dev/null)
  if [[ $? -ne 0 ]] || [[ -z "$weak_json" ]]; then
    echo "❌ Failed to run coverage check"
    return 1
  fi

  local weak_count; weak_count=$(echo "$weak_json" | jq '.categories | length')
  local total_files; total_files=$(echo "$weak_json" | jq '.totals.files')
  local tag_pct; tag_pct=$(echo "$weak_json" | jq '.totals.tagPct')
  local sty_pct; sty_pct=$(echo "$weak_json" | jq '.totals.styPct')

  echo "📊 Totals: $total_files files | Tags: ${tag_pct}% | Styles: ${sty_pct}%"
  echo ""

  if [[ "$weak_count" -eq 0 ]]; then
    echo "✅ All categories healthy — no weak spots found."
    # Log clean review to tracker
    if [[ -f "$tracker" ]]; then
      local updated; updated=$(jq --arg ts "$now" '
        .lastReview = {time: $ts, status: "clean", weakCategories: []}
      ' "$tracker")
      echo "$updated" > "$tracker"
    fi
    echo ""
    # Freshness summary even when coverage is clean
    _review_freshness_summary
    echo ""
    # Full mode: health + audit summary
    if [[ "$full_mode" == true ]]; then
      _review_health_summary
    fi
    _review_today_summary
    return 0
  fi

  echo "⚠️  Found $weak_count weak categories:"
  echo ""

  # Parse and display weak categories with remediation
  local names; names=$(echo "$weak_json" | jq -r '.categories[].name')
  while IFS= read -r cat_name; do
    [[ -z "$cat_name" ]] && continue
    local cat_data; cat_data=$(echo "$weak_json" | jq --arg n "$cat_name" '.categories[] | select(.name == $n)')
    local issues; issues=$(echo "$cat_data" | jq -r '.issues | join(", ")')
    local files; files=$(echo "$cat_data" | jq '.files')
    local avg_tags; avg_tags=$(echo "$cat_data" | jq '.avgTags')
    local style_div; style_div=$(echo "$cat_data" | jq '.styleDiversity')

    echo "  📁 $cat_name ($files files)"
    echo "     Issues: $issues"

    # Suggest remediation per issue type
    if echo "$issues" | grep -q "tags_"; then
      echo "     → Run: memes lint --fix  (auto-tag untagged files)"
    fi
    if echo "$issues" | grep -q "shallow_tags"; then
      echo "     → Add more descriptive tags (avg $avg_tags, target ≥4)"
    fi
    if echo "$issues" | grep -q "styles_"; then
      echo "     → Run: memes lint --fix  (auto-style unstyled files)"
    fi
    if echo "$issues" | grep -q "low_style_diversity"; then
      echo "     → Add memes with different styles (currently $style_div unique). Try: anime, live-action, cartoon, illustrated"
    fi
    echo ""
  done <<< "$names"

  # Log weak review to tracker
  if [[ -f "$tracker" ]]; then
    local weak_names_json; weak_names_json=$(echo "$weak_json" | jq '[.categories[].name]')
    local updated; updated=$(jq --arg ts "$now" --argjson cats "$weak_names_json" '
      .lastReview = {time: $ts, status: "weak", weakCategories: $cats}
    ' "$tracker")
    echo "$updated" > "$tracker"
  fi

  # Freshness summary for weak path too
  _review_freshness_summary

  # Full mode: health + audit summary
  if [[ "$full_mode" == true ]]; then
    _review_health_summary
  fi

  _review_today_summary
  echo "💡 Suggested next step: fix the easiest issue above, then re-run 'memes review'"
  return 0
}

_review_today_summary() {
  # Show today's send activity with category breakdown
  local tracker="$MEMES_DIR/meme-tracker.json"
  local today; today=$(date +%Y-%m-%d)
  local today_data; today_data=$(jq -r --arg d "$today" '
    [.history[] | select((.time? // "") | startswith($d))]
  ' "$tracker" 2>/dev/null)
  local count; count=$(echo "$today_data" | jq 'length')

  if [[ "$count" -eq 0 ]] || [[ -z "$count" ]]; then
    echo "📅 Today: 0 memes sent"
    return 0
  fi

  local cats_summary; cats_summary=$(echo "$today_data" | jq -r '
    group_by(.category) | map({c: .[0].category, n: length})
    | sort_by(-.n) | map("\(.c)(\(.n))") | join(", ")
  ')
  local unique_cats; unique_cats=$(echo "$today_data" | jq '[.[].category] | unique | length')
  local success; success=$(echo "$today_data" | jq '[.[] | select(.result == "success")] | length')
  local failed; failed=$(echo "$today_data" | jq '[.[] | select(.result != "success")] | length')

  local status_text="$count memes"
  if [[ "$failed" -gt 0 ]]; then
    status_text="$success ✅ $failed ❌"
  fi

  echo "📅 Today: $status_text across $unique_cats categories — $cats_summary"
}

_review_health_summary() {
  # Condensed health + audit summary for --full mode
  echo ""
  echo "🏥 Health Summary"
  echo "─────────────────"

  local issues=0

  # Category file counts
  local total_cats=0 low_cats=0 total_files=0
  local min_files=3
  for dir in "$MEMES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local name; name=$(basename "$dir")
    [[ "$name" == .* || "$name" == hooks ]] && continue
    total_cats=$((total_cats + 1))
    local count; count=$(find "$dir" -maxdepth 1 -type f \( -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.webp' \) | wc -l)
    total_files=$((total_files + count))
    [[ $count -lt $min_files ]] && low_cats=$((low_cats + 1))
  done
  if [[ $low_cats -eq 0 ]]; then
    echo "📁 Categories: ✅ $total_cats, all ≥$min_files files ($total_files total)"
  else
    echo "📁 Categories: ⚠️  $low_cats/$total_cats below $min_files files"
    issues=$((issues + 1))
  fi

  # Oversized files
  local oversized=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local size_bytes; size_bytes=$(stat -c%s "$f" 2>/dev/null || echo 0)
    [[ $size_bytes -gt 2097152 ]] && oversized=$((oversized + 1))
  done < <(find "$MEMES_DIR" -mindepth 2 -maxdepth 2 -type f \( -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.webp' \))
  if [[ $oversized -eq 0 ]]; then
    echo "📏 File sizes: ✅ all under 2MB"
  else
    echo "📏 File sizes: ⚠️  $oversized files over 2MB"
    issues=$((issues + 1))
  fi

  # Tracker integrity (quick check)
  local tracker="$MEMES_DIR/meme-tracker.json"
  if [[ -f "$tracker" ]] && command -v jq &>/dev/null; then
    local history_len; history_len=$(jq '.history | length' "$tracker")
    local total_sent; total_sent=$(jq '.totalSent' "$tracker")
    local total_failed; total_failed=$(jq '.totalFailed // 0' "$tracker")
    local success_in_hist; success_in_hist=$(jq '[.history[] | select(.result == "success" or .result == "sent")] | length' "$tracker")
    local failed_in_hist; failed_in_hist=$(jq '[.history[] | select(.result == "failed")] | length' "$tracker")
    if [[ "$total_sent" == "$success_in_hist" && "$total_failed" == "$failed_in_hist" ]]; then
      echo "📊 Tracker: ✅ $history_len entries, counters in sync"
    else
      echo "📊 Tracker: ⚠️  counters out of sync (sent=$total_sent/hist=$success_in_hist, failed=$total_failed/hist=$failed_in_hist)"
      issues=$((issues + 1))
    fi
  fi

  # Style diversity (>70% single-style)
  local tags_file="$MEMES_DIR/tags.json"
  if [[ -f "$tags_file" ]] && jq -e '._styles' "$tags_file" &>/dev/null; then
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
      echo "🎨 Style diversity: ✅ balanced"
    fi
  fi

  # Dormant categories (0 sends in 30 days)
  if [[ -f "$MEMES_DIR/meme-tracker.json" ]]; then
    local cutoff; cutoff=$(date -d '30 days ago' --iso-8601=seconds 2>/dev/null || date -v-30d +%Y-%m-%dT%H:%M:%S%z)
    local all_cats_json
    all_cats_json=$(for dir in "$MEMES_DIR"/*/; do [[ -d "$dir" ]] && basename "$dir"; done | grep -v '^\.\|^hooks$\|^$' | jq -R -s 'split("\n") | map(select(length > 0))')
    local dormant_count
    dormant_count=$(jq -r --arg cutoff "$cutoff" --argjson all_cats "$all_cats_json" '
      [.history[] | select(.time >= $cutoff and (.result == "success" or .result == "sent")) | .category] | unique as $used |
      [$all_cats[] | select(. as $c | $used | index($c) | not)] | length
    ' "$MEMES_DIR/meme-tracker.json")
    if [[ "$dormant_count" -gt 0 ]]; then
      echo "💤 Dormant: ⚠️  $dormant_count categories with 0 sends in 30d"
      issues=$((issues + 1))
    else
      echo "💤 Dormant: ✅ all active in last 30d"
    fi
  fi

  # LFS pointer check
  local lfs_pointers=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local size_bytes; size_bytes=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if [[ $size_bytes -lt 1024 ]] && grep -q 'oid sha256' "$f" 2>/dev/null; then
      lfs_pointers=$((lfs_pointers + 1))
    fi
  done < <(find "$MEMES_DIR" -mindepth 2 -maxdepth 2 -type f \( -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.webp' \))
  [[ $lfs_pointers -gt 0 ]] && { echo "🔗 LFS: ⚠️  $lfs_pointers files are LFS pointers"; issues=$((issues + 1)); }

  echo ""
  if [[ $issues -eq 0 ]]; then
    echo "✅ Health: all clear"
  else
    echo "⚠️  Health: $issues issue(s) — run 'memes health' for details"
  fi
}

_review_freshness_summary() {
  # Show freshness snapshot: stale count + top-3 stalest categories
  local freshness_json; freshness_json=$(cmd_freshness --json 2>/dev/null)
  if [[ $? -ne 0 ]] || [[ -z "$freshness_json" ]]; then
    return 0  # Silently skip if freshness unavailable
  fi

  local stale_count; stale_count=$(echo "$freshness_json" | jq '.staleCount')
  local total; total=$(echo "$freshness_json" | jq '.total')
  local general_stale; general_stale=$(echo "$freshness_json" | jq '[.categories[] | select(.stale == true and .contextual == false)] | length')
  local ctx_stale; ctx_stale=$(echo "$freshness_json" | jq '[.categories[] | select(.stale == true and .contextual == true)] | length')

  echo ""
  if [[ "$stale_count" -gt 0 ]]; then
    echo "🕐 Freshness: $stale_count/$total categories stale ($general_stale general + $ctx_stale contextual)"
  else
    echo "🕐 Freshness: $stale_count/$total categories stale"
  fi

  if [[ "$stale_count" -gt 0 ]]; then
    # Show top-3 stalest (prefer general over contextual)
    local top3; top3=$(echo "$freshness_json" | jq -r '
      [.categories[] | select(.stale == true)] | sort_by(.contextual, -.ageDays) | .[0:3] |
      map("   " + .category + " — " + (if .lastSend == "never" then "never sent" else (.ageDays | tostring) + "d ago" end) + (if .contextual then " (ctx)" else "" end))
      | .[]')
    echo "   Top stalest:"
    echo "$top3"
    echo "   → Run: memes wake  or  memes dormant-blast"
  fi

  # Update tracker lastReview with freshness data
  local tracker="$MEMES_DIR/meme-tracker.json"
  if [[ -f "$tracker" ]]; then
    local updated; updated=$(echo "$freshness_json" | jq --argjson stale "$stale_count" --argjson total "$total" \
      --argjson gen "$general_stale" --argjson ctx "$ctx_stale" \
      --slurpfile t "$tracker" '
      $t[0] | .lastReview.freshness = {staleCount: $stale, total: $total, generalStale: $gen, contextualStale: $ctx}
    ')
    echo "$updated" > "$tracker"
  fi
}

cmd_cron_check() {
  # Fully autonomous cron wrapper: review --full + auto-wake top stale (>14d)
  # Designed to be the single cron entry point — no human intervention needed
  local stale_threshold=14
  local dry_run=false

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --threshold)
        if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -lt 1 ]]; then
          echo "❌ --threshold requires a positive integer (days)" >&2
          return 1
        fi
        stale_threshold="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      *)
        echo "❌ Unknown flag for cron-check: $1" >&2
        return 1
        ;;
    esac
  done

  # Run full review (prints report to stdout)
  cmd_review --full
  echo ""

  # Check freshness for auto-wake candidates
  local freshness_json; freshness_json=$(cmd_freshness --json 2>/dev/null)
  if [[ $? -ne 0 ]] || [[ -z "$freshness_json" ]]; then
    echo "⏭️  Freshness data unavailable — skipping auto-wake"
    return 0
  fi

  # Find categories stale beyond threshold
  local very_stale; very_stale=$(echo "$freshness_json" | jq -r --argjson threshold "$stale_threshold" '
    [.categories[] | select(.stale == true and .ageDays >= $threshold)]
    | sort_by(-.ageDays)
    | .[0] // empty
    | .category')

  if [[ -z "$very_stale" ]]; then
    echo "✅ No categories stale beyond ${stale_threshold}d — no auto-wake needed"
    return 0
  fi

  local stale_days; stale_days=$(echo "$freshness_json" | jq -r --arg cat "$very_stale" '
    [.categories[] | select(.category == $cat)] | .[0].ageDays')

  if [[ "$dry_run" == true ]]; then
    echo "🧪 [DRY-RUN] Would auto-wake: $very_stale (${stale_days}d stale, threshold ${stale_threshold}d)"
    return 0
  fi

  echo "🔄 Auto-waking: $very_stale (${stale_days}d stale, threshold ${stale_threshold}d)"
  echo ""

  # Wake sends to the configured default channel
  cmd_wake --send --caption "💤 auto-wake — $very_stale hasn't been used in ${stale_days}d"
}

cmd_retire() {
  local source="${1:-}"
  local target="${2:-}"
  local dry_run=false

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=true; shift ;;
      *) if [[ -z "$source" || "$source" == --* ]]; then source="$1"; elif [[ -z "$target" || "$target" == --* ]]; then target="$1"; fi; shift ;;
    esac
  done
  # Re-resolve after flag parsing
  source="${source:-}"; target="${target:-}"

  [[ -z "$source" || -z "$target" ]] && { echo "Usage: memes retire <source-category> <target-category> [--dry-run]" >&2; echo "  Merges all memes from <source> into <target>, updates tags.json and tracker." >&2; exit 1; }

  source=$(_resolve_category "$source")
  target=$(_resolve_category "$target")

  local src_dir="$MEMES_DIR/$source"
  local tgt_dir="$MEMES_DIR/$target"

  [[ ! -d "$src_dir" ]] && { echo "❌ Source category '$source' not found" >&2; exit 1; }
  [[ ! -d "$tgt_dir" ]] && { echo "❌ Target category '$target' not found" >&2; exit 1; }
  [[ "$source" == "$target" ]] && { echo "❌ Source and target must be different" >&2; exit 1; }

  # Count source files
  local -a src_files=()
  while IFS= read -r f; do src_files+=("$f"); done < <(find "$src_dir" -maxdepth 1 -type f \( -name '*.gif' -o -name '*.jpg' -o -name '*.png' -o -name '*.webp' \) 2>/dev/null)
  local src_count=${#src_files[@]}

  if [[ $src_count -eq 0 ]]; then
    echo "⚠️  Source category '$source' has no meme files"
  fi

  echo "🗑️  Retire: $source → $target"
  echo "   Files to move: $src_count"
  echo ""

  if $dry_run; then
    echo "🧪 [DRY-RUN] Would:"
    echo "   - Move $src_count files from $source/ to $target/"
    echo "   - Update tags.json: re-key $source/... → $target/..."
    echo "   - Update tracker: rewrite history category $source → $target"
    echo "   - Remove aliases pointing to $source"
    echo "   - Delete $source/ directory"
    if [[ $src_count -gt 0 ]]; then
      echo ""
      echo "   Files:"
      for f in "${src_files[@]}"; do
        local bn; bn=$(basename "$f")
        local tgt_name="$bn"
        [[ -f "$tgt_dir/$bn" ]] && tgt_name="${source}-${bn}"
        echo "     $source/$bn → $target/$tgt_name"
      done
    fi
    return 0
  fi

  # 1. Move files (handle name collisions by prefixing source category)
  local moved=0
  local rename_map_file; rename_map_file=$(mktemp)
  echo '{' > "$rename_map_file"
  local first_entry=true
  for f in "${src_files[@]}"; do
    local bn; bn=$(basename "$f")
    local actual_bn="$bn"
    local dest="$tgt_dir/$bn"
    if [[ -f "$dest" ]]; then
      actual_bn="${source}-${bn}"
      dest="$tgt_dir/$actual_bn"
      echo "   ⚠️  Name collision: $bn → $actual_bn"
    fi
    mv "$f" "$dest"
    moved=$((moved + 1))
    # Record mapping: original_basename → actual_basename
    $first_entry || echo ',' >> "$rename_map_file"
    printf '  "%s": "%s"' "$bn" "$actual_bn" >> "$rename_map_file"
    first_entry=false
  done
  echo '' >> "$rename_map_file"
  echo '}' >> "$rename_map_file"
  echo "   ✅ Moved $moved files"

  # 2. Update tags.json: re-key source/X → target/X entries, merge _styles too
  local tags_file="$MEMES_DIR/tags.json"
  if [[ -f "$tags_file" ]]; then
    local tmp; tmp=$(mktemp)
    python3 -c "
import json
with open('$tags_file') as f:
    data = json.load(f)
with open('$rename_map_file') as f:
    rename_map = json.load(f)
source = '$source'
target = '$target'
moved_keys = 0
# Re-key tag entries
keys_to_move = [k for k in data if k.startswith(source + '/') and k not in ('_meta', '_styles')]
for key in keys_to_move:
    bn = key[len(source)+1:]
    actual_bn = rename_map.get(bn, bn)
    new_key = target + '/' + actual_bn
    data[new_key] = data.pop(key)
    moved_keys += 1
# Re-key _styles entries
styles = data.get('_styles', {})
style_keys = [k for k in styles if k.startswith(source + '/')]
for key in style_keys:
    bn = key[len(source)+1:]
    actual_bn = rename_map.get(bn, bn)
    new_key = target + '/' + actual_bn
    styles[new_key] = styles.pop(key)
# Update categoryCounts in _meta
meta = data.get('_meta', {})
cc = meta.get('categoryCounts', {})
if source in cc:
    cc[target] = cc.get(target, 0) + cc.pop(source, 0)
    meta['categoryCounts'] = cc
with open('$tmp', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\\n')
print(f'   ✅ Re-keyed {moved_keys} tag entries + styles')
" 2>&1
    if [[ -f "$tmp" && -s "$tmp" ]]; then
      mv "$tmp" "$tags_file"
    else
      rm -f "$tmp"
      echo "   ⚠️  tags.json update failed, manual fix needed" >&2
    fi
  fi
  rm -f "$rename_map_file"

  # 3. Update tracker: rewrite history category, merge counts
  local tracker_file="$MEMES_DIR/meme-tracker.json"
  if [[ -f "$tracker_file" ]]; then
    local tmp; tmp=$(mktemp)
    python3 -c "
import json
with open('$tracker_file') as f:
    data = json.load(f)
source = '$source'
target = '$target'
rewritten = 0
# Rewrite history entries
for entry in data.get('history', []):
    if entry.get('category') == source:
        entry['category'] = target
        rewritten += 1
# Merge counts
counts = data.get('counts', {})
if source in counts:
    counts[target] = counts.get(target, 0) + counts.pop(source, 0)
# Merge categoryCounts
cc = data.get('categoryCounts', {})
if source in cc:
    cc[target] = cc.get(target, 0) + cc.pop(source, 0)
with open('$tmp', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\\n')
print(f'   ✅ Rewritten {rewritten} history entries')
" 2>&1
    if [[ -f "$tmp" && -s "$tmp" ]]; then
      mv "$tmp" "$tracker_file"
    else
      rm -f "$tmp"
      echo "   ⚠️  tracker update failed" >&2
    fi
  fi

  # 4. Remove source directory
  rmdir "$src_dir" 2>/dev/null && echo "   ✅ Removed empty $source/ directory" || echo "   ⚠️  $source/ not empty (non-meme files remain), remove manually"

  # 5. Note about aliases
  echo ""
  echo "   📝 Remember: remove aliases for '$source' from _resolve_category() in this script"
  echo ""
  echo "Done! Run 'memes coverage' to verify."
}

# Perceptual hash near-duplicate detection helper
_dedup_phash() {
  local fix="$1" threshold="$2"
  local tag_file="$MEMES_DIR/tags.json"
  local tracker_file="$MEMES_DIR/meme-tracker.json"
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  echo "🔍 Meme Dedup — Perceptual Hash (pHash) Scan"
  echo "==============================================="
  echo "Threshold: hamming distance ≤ $threshold"
  echo ""

  cd "$MEMES_DIR"

  # Compute pHash for all images via Python
  local phash_json
  phash_json=$(python3 -c "
import imagehash, json, os, sys
from PIL import Image

memes_dir = sys.argv[1]
threshold = int(sys.argv[2])

# Collect all image files
files = []
for entry in sorted(os.listdir(memes_dir)):
    subdir = os.path.join(memes_dir, entry)
    if not os.path.isdir(subdir) or entry.startswith('.') or entry in ('hooks',):
        continue
    for fname in sorted(os.listdir(subdir)):
        ext = os.path.splitext(fname)[1].lower()
        if ext in ('.gif', '.png', '.jpg', '.jpeg', '.webp'):
            files.append(os.path.join(entry, fname))

# Compute pHash for each file
hashes = {}
errors = []
for fpath in files:
    try:
        img = Image.open(os.path.join(memes_dir, fpath))
        try:
            if hasattr(img, 'n_frames') and img.n_frames > 1:
                img.seek(0)
        except Exception:
            img.seek(0)  # n_frames failed (e.g. corrupt GIF frame), reset to frame 0
        h = imagehash.phash(img.convert('RGB'))
        hashes[fpath] = str(h)
    except Exception as e:
        errors.append({'file': fpath, 'error': str(e)})

# Group near-duplicates by pairwise comparison
file_list = list(hashes.keys())
hash_list = [imagehash.hex_to_hash(hashes[f]) for f in file_list]
visited = set()
groups = []
for i in range(len(file_list)):
    if i in visited:
        continue
    group = [i]
    for j in range(i + 1, len(file_list)):
        if j in visited:
            continue
        dist = hash_list[i] - hash_list[j]
        if dist <= threshold:
            group.append(j)
            visited.add(j)
    if len(group) > 1:
        visited.add(i)
        groups.append([{'file': file_list[idx], 'hash': hashes[file_list[idx]], 'dist': int(hash_list[i] - hash_list[idx])} for idx in group])

result = {'groups': groups, 'totalFiles': len(files), 'totalHashed': len(hashes), 'errors': errors}
print(json.dumps(result))
" "$MEMES_DIR" "$threshold" 2>&1)

  # Check for Python errors
  if ! echo "$phash_json" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    echo "❌ pHash computation failed:" >&2
    echo "$phash_json" >&2
    return 1
  fi

  # Parse and display results
  local total_files total_hashed num_groups num_errors
  total_files=$(echo "$phash_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["totalFiles"])')
  total_hashed=$(echo "$phash_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["totalHashed"])')
  num_groups=$(echo "$phash_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["groups"]))')
  num_errors=$(echo "$phash_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["errors"]))')

  echo "📊 Scanned: $total_files files, hashed: $total_hashed"
  if [[ "$num_errors" -gt 0 ]]; then
    echo "⚠️  $num_errors files failed to hash:"
    echo "$phash_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for e in data["errors"]:
    print("   \u274c " + e["file"] + ": " + e["error"])
'
  fi
  echo ""

  if [[ "$num_groups" -eq 0 ]]; then
    echo "✅ No perceptual near-duplicates found (threshold ≤ $threshold)."
    return 0
  fi

  # Display groups and collect fix data
  local total_removable=0 bytes_saved=0
  local -a remove_files=() merge_pairs=()

  # Write display script to temp file to avoid bash/python quoting issues
  cat > "$tmpdir/phash_display.py" << 'PYEOF'
import json, sys, os

data = json.load(sys.stdin)
memes_dir = sys.argv[1]

removable = []
for gi, group in enumerate(data["groups"]):
    cats = set(os.path.dirname(f["file"]) for f in group)
    same_cat = len(cats) == 1
    cat_name = list(cats)[0]
    if same_cat:
        print(f"## Group {gi+1} \u2014 Same-category near-duplicates in {cat_name}/")
    else:
        print(f"## Group {gi+1} \u2014 Cross-category near-duplicates")

    for f in group:
        fpath = os.path.join(memes_dir, f["file"])
        sz = os.path.getsize(fpath) if os.path.exists(fpath) else 0
        fname = f["file"]
        fhash = f["hash"]
        fdist = f["dist"]
        print(f"   \U0001f4c4 {fname}  ({sz // 1024}KB) hash={fhash} (dist={fdist})")

    if same_cat:
        best = group[0]
        for f in group[1:]:
            fname = os.path.splitext(os.path.basename(f["file"]))[0]
            best_fname = os.path.splitext(os.path.basename(best["file"]))[0]
            if len(fname) > len(best_fname) or (len(fname) == len(best_fname) and fname < best_fname):
                best = f
        print(f"   \u2705 Keep: {best['file']}")
        for f in group:
            if f["file"] != best["file"]:
                fpath = os.path.join(memes_dir, f["file"])
                sz = os.path.getsize(fpath) if os.path.exists(fpath) else 0
                print(f"   \U0001f5d1\ufe0f  Remove: {f['file']}")
                removable.append({"survivor": best["file"], "removed": f["file"], "bytes": sz})
    else:
        print("   \u2139\ufe0f  Cross-category \u2014 kept in all locations (different semantic contexts)")
        print("   \U0001f4a1 To consolidate, use: memes retire <source> <target>")
    print()

print("__PHASH_FIX_DATA__" + json.dumps({"removable": removable}), file=sys.stderr)
PYEOF

  echo "$phash_json" | python3 "$tmpdir/phash_display.py" "$MEMES_DIR" 2>"$tmpdir/fix_data.txt"

  # Parse fix data from stderr
  local fix_json=""
  if [[ -f "$tmpdir/fix_data.txt" ]]; then
    fix_json=$(grep '^__PHASH_FIX_DATA__' "$tmpdir/fix_data.txt" | sed 's/^__PHASH_FIX_DATA__//' || true)
  fi

  # Validate fix_json is parseable
  if [[ -z "$fix_json" ]]; then
    fix_json='{}'
  fi

  total_removable=$(echo "$fix_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("removable",[])))')
  bytes_saved=$(echo "$fix_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(r["bytes"] for r in d.get("removable",[])))')

  echo "=== Summary ==="
  echo "Near-duplicate groups: $num_groups"
  echo "Removable files: $total_removable (same-category near-dupes)"
  if [[ "$bytes_saved" -gt 0 ]]; then
    echo "Space savings: ~$(( bytes_saved / 1024 ))KB"
  fi

  if [[ $total_removable -eq 0 ]]; then
    echo ""
    echo "✅ No same-category near-duplicates to fix."
    return 0
  fi

  if [[ "$fix" != true ]]; then
    echo ""
    echo "🧪 Dry-run mode. Run 'memes dedup --phash --fix' to remove near-duplicates and merge tags."
    echo "💡 Review each group visually before running --fix (perceptual matches may differ semantically)."
    return 0
  fi

  echo ""
  echo "🔧 Fixing same-category near-duplicates..."

  # Build merge pairs from fix data
  local merge_json
  merge_json=$(echo "$fix_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
result = [{"survivor": r["survivor"], "removed": r["removed"]} for r in data.get("removable", [])]
print(json.dumps(result))
')

  # Reuse the exact same tags.json + tracker update logic from exact dedup
  if [[ -f "$tag_file" ]]; then
    local tmp_tags
    tmp_tags=$(mktemp)
    python3 -c "
import json, sys, os
merges = json.loads(sys.argv[1])
with open(sys.argv[2]) as f:
    data = json.load(f)
for m in merges:
    surv = m['survivor']
    rem = m['removed']
    surv_tags = data.get(surv, [])
    rem_tags = data.get(rem, [])
    if isinstance(surv_tags, list) and isinstance(rem_tags, list):
        merged = list(dict.fromkeys(surv_tags + rem_tags))
        data[surv] = merged
    data.pop(rem, None)
    styles = data.get('_styles', {})
    if rem in styles and surv not in styles:
        styles[surv] = styles[rem]
    styles.pop(rem, None)
    meta = data.get('_meta', {})
    cc = meta.get('categoryCounts', {})
    cat = os.path.dirname(rem)
    if cat in cc:
        cc[cat] = max(0, cc.get(cat, 0) - 1)
    meta['totalFiles'] = meta.get('totalFiles', 0) - 1
    print(f'   ✅ Merged tags: {rem} → {surv}')
with open(sys.argv[3], 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\\n')
" "$merge_json" "$tag_file" "$tmp_tags" 2>&1

    if [[ -f "$tmp_tags" && -s "$tmp_tags" ]]; then
      mv "$tmp_tags" "$tag_file"
    else
      rm -f "$tmp_tags"
      echo "   ⚠️  tags.json update failed" >&2
      return 1
    fi
  fi

  if [[ -f "$tracker_file" ]]; then
    local tmp_tracker
    tmp_tracker=$(mktemp)
    python3 -c "
import json, sys, os
merges = json.loads(sys.argv[1])
with open(sys.argv[2]) as f:
    data = json.load(f)
rename_map = {}
for m in merges:
    rename_map[os.path.basename(m['removed'])] = os.path.basename(m['survivor'])
rewritten = 0
for entry in data.get('history', []):
    if entry.get('file') in rename_map:
        entry['file'] = rename_map[entry['file']]
        rewritten += 1
counts = data.get('counts', {})
for old_f, new_f in rename_map.items():
    if old_f in counts:
        counts[new_f] = counts.get(new_f, 0) + counts.pop(old_f, 0)
with open(sys.argv[3], 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\\n')
if rewritten > 0:
    print(f'   ✅ Tracker: rewritten {rewritten} history entries')
else:
    print('   ✅ Tracker: no history entries needed rewriting')
" "$merge_json" "$tracker_file" "$tmp_tracker" 2>&1

    if [[ -f "$tmp_tracker" && -s "$tmp_tracker" ]]; then
      mv "$tmp_tracker" "$tracker_file"
    else
      rm -f "$tmp_tracker"
      echo "   ⚠️  tracker update failed" >&2
    fi
  fi

  # Remove duplicate files
  local removed_count=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ -f "$MEMES_DIR/$f" ]]; then
      (cd "$MEMES_DIR" && git rm -q "$f" 2>/dev/null) || rm -f "$MEMES_DIR/$f"
      echo "   🗑️  Deleted: $f"
      removed_count=$((removed_count + 1))
    fi
  done < <(echo "$fix_json" | python3 -c 'import json,sys; [print(r["removed"]) for r in json.load(sys.stdin).get("removable",[])]')

  echo ""
  echo "✅ pHash dedup complete. Removed $removed_count files, saved ~$(( bytes_saved / 1024 ))KB."
  echo "   Run 'memes coverage' to verify health."
}

cmd_dedup() {
  local fix=false phash=false phash_threshold=10
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fix) fix=true ;;
      --phash) phash=true ;;
      --threshold)
        shift
        if [[ -z "${1:-}" ]] || ! [[ "$1" =~ ^[0-9]+$ ]] || [[ "$1" -eq 0 ]]; then
          echo "❌ --threshold requires a positive integer (hamming distance)" >&2; return 1
        fi
        phash_threshold="$1"
        ;;
      -h|--help)
        echo "Usage: memes dedup [--fix] [--phash [--threshold N]]" >&2
        echo "  Find duplicate files across/within categories." >&2
        echo "  Default: exact md5 match. --phash uses perceptual hash (near-duplicates)." >&2
        echo "  --threshold N: hamming distance for pHash (default 10, lower=stricter)." >&2
        echo "  Default: dry-run. --fix removes duplicates, merges tags, updates tracker." >&2
        return 0 ;;
      *) echo "Usage: memes dedup [--fix] [--phash [--threshold N]]" >&2; return 1 ;;
    esac
    shift
  done

  if [[ "$phash" == true ]]; then
    _dedup_phash "$fix" "$phash_threshold"
    return $?
  fi

  local tag_file="$MEMES_DIR/tags.json"
  local tracker_file="$MEMES_DIR/meme-tracker.json"

  echo "🔍 Meme Dedup — Exact Duplicate Scan"
  echo "====================================="
  echo ""

  # Build md5 → file list mapping
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  cd "$MEMES_DIR"
  find . -maxdepth 2 -type f \( -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.webp' \) \
    -exec md5sum {} \; | sed 's|\./||' > "$tmpdir/all_md5.txt"

  # Find duplicate md5s
  local dup_md5s
  dup_md5s=$(awk '{print $1}' "$tmpdir/all_md5.txt" | sort | uniq -d)

  if [[ -z "$dup_md5s" ]]; then
    echo "✅ No exact duplicates found across ${#MEMES_CONTEXTUAL_CATS[@]}+ categories."
    return 0
  fi

  local total_groups=0 same_cat_groups=0 cross_cat_groups=0
  local total_removable=0 bytes_saved=0
  # Collect removable files for --fix
  local -a remove_files=()
  local -a remove_keys=()
  # Collect tag merges: survivor_key -> merged_tags (newline-separated pairs)
  local -a merge_pairs=()

  while IFS= read -r md5; do
    local -a files=()
    while IFS= read -r line; do
      local fpath="${line#* }"
      # strip leading spaces from md5sum output format
      fpath="$(echo "$fpath" | sed 's/^ *//')"
      files+=("$fpath")
    done < <(grep "^$md5 " "$tmpdir/all_md5.txt")

    [[ ${#files[@]} -lt 2 ]] && continue
    total_groups=$((total_groups + 1))

    # Categorize: same-category vs cross-category
    local -a cats=()
    for f in "${files[@]}"; do
      cats+=("$(dirname "$f")")
    done
    local unique_cats
    unique_cats=$(printf '%s\n' "${cats[@]}" | sort -u | wc -l)

    if [[ $unique_cats -eq 1 ]]; then
      same_cat_groups=$((same_cat_groups + 1))
      echo "## Same-category duplicates in ${cats[0]}/"
    else
      cross_cat_groups=$((cross_cat_groups + 1))
      echo "## Cross-category duplicates"
    fi

    for f in "${files[@]}"; do
      local sz
      sz=$(stat -c%s "$MEMES_DIR/$f" 2>/dev/null || echo 0)
      echo "   📄 $f  ($(( sz / 1024 ))KB)"
    done

    # Decide which to keep: prefer longer filename (more descriptive), then alphabetically first
    # For cross-category, keep all (different semantic contexts) — just report
    if [[ $unique_cats -eq 1 ]]; then
      # Same category: keep the best-named file, remove others
      local best="${files[0]}"
      local best_len=${#best}
      for f in "${files[@]:1}"; do
        local fname
        fname=$(basename "$f" | sed 's/\.[^.]*$//')
        local best_fname
        best_fname=$(basename "$best" | sed 's/\.[^.]*$//')
        # Prefer longer basename (more descriptive), break ties alphabetically
        if [[ ${#fname} -gt ${#best_fname} ]] || { [[ ${#fname} -eq ${#best_fname} ]] && [[ "$fname" < "$best_fname" ]]; }; then
          best="$f"
        fi
      done

      echo "   ✅ Keep: $best"
      for f in "${files[@]}"; do
        if [[ "$f" != "$best" ]]; then
          local sz
          sz=$(stat -c%s "$MEMES_DIR/$f" 2>/dev/null || echo 0)
          bytes_saved=$((bytes_saved + sz))
          total_removable=$((total_removable + 1))
          echo "   🗑️  Remove: $f"
          remove_files+=("$f")
          remove_keys+=("$f")
          merge_pairs+=("$best|$f")
        fi
      done
    else
      echo "   ℹ️  Cross-category — kept in all locations (different semantic contexts)"
      echo "   💡 To consolidate, use: memes retire <source> <target>"
    fi
    echo ""
  done <<< "$dup_md5s"

  # Summary
  echo "=== Summary ==="
  echo "Duplicate groups: $total_groups ($same_cat_groups same-cat, $cross_cat_groups cross-cat)"
  echo "Removable files: $total_removable (same-category dupes)"
  if [[ $bytes_saved -gt 0 ]]; then
    echo "Space savings: ~$(( bytes_saved / 1024 ))KB"
  fi

  if [[ $total_removable -eq 0 ]]; then
    echo ""
    echo "✅ No same-category duplicates to fix."
    return 0
  fi

  if [[ "$fix" != true ]]; then
    echo ""
    echo "🧪 Dry-run mode. Run 'memes dedup --fix' to remove duplicates and merge tags."
    return 0
  fi

  echo ""
  echo "🔧 Fixing same-category duplicates..."

  # Process tag merges and file removals via Python for atomic tags.json update
  local merge_json="[]"
  for pair in "${merge_pairs[@]}"; do
    local survivor="${pair%%|*}"
    local removed="${pair##*|}"
    merge_json=$(python3 -c "
import json, sys
arr = json.loads(sys.argv[1])
arr.append({'survivor': sys.argv[2], 'removed': sys.argv[3]})
print(json.dumps(arr))
" "$merge_json" "$survivor" "$removed")
  done

  # Update tags.json: merge tags from removed into survivor, delete removed entries
  if [[ -f "$tag_file" ]]; then
    local tmp_tags
    tmp_tags=$(mktemp)
    python3 -c "
import json, sys
merges = json.loads(sys.argv[1])
with open(sys.argv[2]) as f:
    data = json.load(f)
for m in merges:
    surv = m['survivor']
    rem = m['removed']
    # Merge tags
    surv_tags = data.get(surv, [])
    rem_tags = data.get(rem, [])
    if isinstance(surv_tags, list) and isinstance(rem_tags, list):
        merged = list(dict.fromkeys(surv_tags + rem_tags))  # preserve order, dedup
        data[surv] = merged
    # Remove entry
    data.pop(rem, None)
    # Merge styles
    styles = data.get('_styles', {})
    if rem in styles and surv not in styles:
        styles[surv] = styles[rem]
    styles.pop(rem, None)
    # Update categoryCounts
    meta = data.get('_meta', {})
    cc = meta.get('categoryCounts', {})
    import os
    cat = os.path.dirname(rem)
    if cat in cc:
        cc[cat] = max(0, cc.get(cat, 0) - 1)
    meta['totalFiles'] = meta.get('totalFiles', 0) - 1
    print(f'   ✅ Merged tags: {rem} → {surv}')
with open(sys.argv[3], 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\\n')
" "$merge_json" "$tag_file" "$tmp_tags" 2>&1

    if [[ -f "$tmp_tags" && -s "$tmp_tags" ]]; then
      mv "$tmp_tags" "$tag_file"
    else
      rm -f "$tmp_tags"
      echo "   ⚠️  tags.json update failed" >&2
      return 1
    fi
  fi

  # Update tracker: rewrite history entries referencing removed files to survivor
  if [[ -f "$tracker_file" ]]; then
    local tmp_tracker
    tmp_tracker=$(mktemp)
    python3 -c "
import json, sys, os
merges = json.loads(sys.argv[1])
with open(sys.argv[2]) as f:
    data = json.load(f)
rename_map = {}
for m in merges:
    rem = m['removed']
    surv = m['survivor']
    rem_file = os.path.basename(rem)
    surv_file = os.path.basename(surv)
    rename_map[rem_file] = surv_file
rewritten = 0
for entry in data.get('history', []):
    if entry.get('file') in rename_map:
        entry['file'] = rename_map[entry['file']]
        rewritten += 1
# Merge per-file counts if present
counts = data.get('counts', {})
for old_f, new_f in rename_map.items():
    if old_f in counts:
        counts[new_f] = counts.get(new_f, 0) + counts.pop(old_f, 0)
with open(sys.argv[3], 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\\n')
if rewritten > 0:
    print(f'   ✅ Tracker: rewritten {rewritten} history entries')
else:
    print('   ✅ Tracker: no history entries needed rewriting')
" "$merge_json" "$tracker_file" "$tmp_tracker" 2>&1

    if [[ -f "$tmp_tracker" && -s "$tmp_tracker" ]]; then
      mv "$tmp_tracker" "$tracker_file"
    else
      rm -f "$tmp_tracker"
      echo "   ⚠️  tracker update failed" >&2
    fi
  fi

  # Remove duplicate files
  for f in "${remove_files[@]}"; do
    if [[ -f "$MEMES_DIR/$f" ]]; then
      (cd "$MEMES_DIR" && git rm -q "$f" 2>/dev/null) || rm -f "$MEMES_DIR/$f"
      echo "   🗑️  Deleted: $f"
    fi
  done

  echo ""
  echo "✅ Dedup complete. Removed $total_removable files, saved ~$(( bytes_saved / 1024 ))KB."
  echo "   Run 'memes coverage' to verify health."
}

cmd_gallery() {
  local output_file="$MEMES_DIR/gallery.html"
  local filter_cat=""
  local filter_style=""
  local filter_tag=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output|-o) output_file="$2"; shift 2 ;;
      --category|-c) filter_cat="$2"; shift 2 ;;
      --style|-s) filter_style="$2"; shift 2 ;;
      --tag|-t) filter_tag="$2"; shift 2 ;;
      *) echo "Unknown gallery option: $1" >&2; return 1 ;;
    esac
  done

  local tags_file="$MEMES_DIR/tags.json"
  [[ ! -f "$tags_file" ]] && { echo "Error: tags.json not found" >&2; return 1; }

  # Generate HTML via Python for robust JSON parsing + HTML generation
  python3 - "$MEMES_DIR" "$output_file" "$filter_cat" "$filter_style" "$filter_tag" << 'PYEOF'
import json, sys, os, html, base64
from pathlib import Path
from collections import defaultdict

memes_dir = Path(sys.argv[1])
output_file = sys.argv[2]
filter_cat = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
filter_style = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None
filter_tag = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else None

with open(memes_dir / "tags.json") as f:
    data = json.load(f)

meta = data.get("_meta", {})
styles = data.get("_styles", {})

# Collect memes by category
categories = defaultdict(list)
for key, tags in data.items():
    if key.startswith("_"):
        continue
    if "/" not in key:
        continue
    cat, filename = key.split("/", 1)
    if filter_cat and cat != filter_cat:
        continue
    style = styles.get(key, "unknown")
    if filter_style and style != filter_style:
        continue
    if filter_tag and filter_tag not in tags:
        continue
    filepath = memes_dir / cat / filename
    if not filepath.exists():
        continue
    ext = filepath.suffix.lower()
    mime = {"gif": "image/gif", "jpg": "image/jpeg", "jpeg": "image/jpeg",
            "png": "image/png", "webp": "image/webp"}.get(ext.lstrip("."), "image/png")
    categories[cat].append({
        "filename": filename,
        "path": str(filepath),
        "tags": tags if isinstance(tags, list) else [],
        "style": style,
        "mime": mime,
        "size_kb": filepath.stat().st_size / 1024,
    })

# Sort categories alphabetically, files within each by name
all_tags = set()
all_styles = set()
total = 0
for cat in categories:
    categories[cat].sort(key=lambda m: m["filename"])
    for m in categories[cat]:
        all_tags.update(m["tags"])
        all_styles.add(m["style"])
        total += 1

sorted_cats = sorted(categories.keys())

# Build tag nav
tag_counts = defaultdict(int)
style_counts = defaultdict(int)
for cat in sorted_cats:
    for m in categories[cat]:
        for t in m["tags"]:
            tag_counts[t] += 1
        style_counts[m["style"]] += 1

html_out = []
html_out.append("""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Kagura Meme Gallery</title>
<style>
:root {
  --bg: #1a1a2e;
  --card-bg: #16213e;
  --accent: #e94560;
  --text: #eee;
  --text-dim: #888;
  --tag-bg: #0f3460;
  --tag-text: #a8d8ea;
  --border: #2a2a4a;
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  background: var(--bg);
  color: var(--text);
  padding: 20px;
}
h1 {
  text-align: center;
  margin-bottom: 8px;
  font-size: 1.8em;
  color: var(--accent);
}
.subtitle {
  text-align: center;
  color: var(--text-dim);
  margin-bottom: 20px;
  font-size: 0.9em;
}
.filters {
  display: flex;
  gap: 12px;
  justify-content: center;
  flex-wrap: wrap;
  margin-bottom: 24px;
  padding: 12px;
  background: var(--card-bg);
  border-radius: 8px;
  border: 1px solid var(--border);
}
.filters label {
  color: var(--text-dim);
  font-size: 0.85em;
}
.filters input, .filters select {
  background: var(--bg);
  color: var(--text);
  border: 1px solid var(--border);
  border-radius: 4px;
  padding: 4px 8px;
  font-size: 0.85em;
}
.filters input:focus, .filters select:focus {
  outline: none;
  border-color: var(--accent);
}
.toc {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  justify-content: center;
  margin-bottom: 24px;
}
.toc a {
  color: var(--tag-text);
  background: var(--tag-bg);
  padding: 4px 10px;
  border-radius: 12px;
  text-decoration: none;
  font-size: 0.8em;
  transition: background 0.2s;
}
.toc a:hover { background: var(--accent); color: #fff; }
.toc a .count { opacity: 0.6; margin-left: 4px; }
.category {
  margin-bottom: 32px;
}
.category h2 {
  font-size: 1.3em;
  margin-bottom: 12px;
  padding-bottom: 6px;
  border-bottom: 2px solid var(--accent);
  display: flex;
  align-items: center;
  gap: 8px;
}
.category h2 .cat-count {
  font-size: 0.7em;
  color: var(--text-dim);
  font-weight: normal;
}
.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
  gap: 12px;
}
.card {
  background: var(--card-bg);
  border: 1px solid var(--border);
  border-radius: 8px;
  overflow: hidden;
  transition: transform 0.2s, box-shadow 0.2s;
  cursor: pointer;
}
.card:hover {
  transform: translateY(-2px);
  box-shadow: 0 4px 12px rgba(233, 69, 96, 0.3);
}
.card .img-wrap {
  width: 100%;
  height: 160px;
  display: flex;
  align-items: center;
  justify-content: center;
  background: #111;
  overflow: hidden;
}
.card img {
  max-width: 100%;
  max-height: 160px;
  object-fit: contain;
}
.card .info {
  padding: 8px;
}
.card .filename {
  font-size: 0.75em;
  color: var(--text-dim);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  margin-bottom: 4px;
}
.card .style-badge {
  display: inline-block;
  font-size: 0.65em;
  padding: 2px 6px;
  border-radius: 8px;
  margin-bottom: 4px;
}
.style-anime { background: #4a1942; color: #f0a; }
.style-cartoon { background: #1a4731; color: #6f6; }
.style-live-action { background: #3d2e0f; color: #fd0; }
.style-meme { background: #0f3460; color: #8cf; }
.style-animal { background: #2d4a1a; color: #9d6; }
.style-unknown { background: #333; color: #999; }
.card .tags {
  display: flex;
  flex-wrap: wrap;
  gap: 3px;
}
.card .tag {
  font-size: 0.6em;
  background: var(--tag-bg);
  color: var(--tag-text);
  padding: 1px 5px;
  border-radius: 6px;
}
.card .size {
  font-size: 0.6em;
  color: var(--text-dim);
  margin-top: 4px;
}
/* Modal */
.modal-overlay {
  display: none;
  position: fixed;
  top: 0; left: 0; right: 0; bottom: 0;
  background: rgba(0,0,0,0.85);
  z-index: 1000;
  justify-content: center;
  align-items: center;
}
.modal-overlay.active { display: flex; }
.modal-content {
  max-width: 90vw;
  max-height: 90vh;
  position: relative;
}
.modal-content img {
  max-width: 90vw;
  max-height: 85vh;
  object-fit: contain;
  border-radius: 8px;
}
.modal-caption {
  text-align: center;
  margin-top: 8px;
  color: var(--text-dim);
  font-size: 0.85em;
}
.modal-close {
  position: absolute;
  top: -30px;
  right: 0;
  color: #fff;
  font-size: 1.5em;
  cursor: pointer;
  background: none;
  border: none;
}
#no-results {
  display: none;
  text-align: center;
  color: var(--text-dim);
  padding: 40px;
  font-size: 1.2em;
}
</style>
</head>
<body>
""")

html_out.append(f'<h1>🌸 Kagura Meme Gallery</h1>')
html_out.append(f'<p class="subtitle">{total} memes across {len(sorted_cats)} categories | {len(all_tags)} tags | {len(all_styles)} styles</p>')

# Filters
html_out.append('<div class="filters">')
html_out.append('<label>Search: <input type="text" id="searchBox" placeholder="filename or tag..." oninput="filterCards()"></label>')
style_options = ''.join(f'<option value="{s}">{s} ({style_counts[s]})</option>' for s in sorted(all_styles))
html_out.append(f'<label>Style: <select id="styleFilter" onchange="filterCards()"><option value="">all styles</option>{style_options}</select></label>')
html_out.append('</div>')

# TOC
html_out.append('<div class="toc">')
for cat in sorted_cats:
    cnt = len(categories[cat])
    html_out.append(f'<a href="#{html.escape(cat)}">{html.escape(cat)}<span class="count">({cnt})</span></a>')
html_out.append('</div>')

# Categories
for cat in sorted_cats:
    memes = categories[cat]
    html_out.append(f'<div class="category" data-category="{html.escape(cat)}" id="{html.escape(cat)}">')
    html_out.append(f'<h2>{html.escape(cat)} <span class="cat-count">{len(memes)} files</span></h2>')
    html_out.append('<div class="grid">')
    for m in memes:
        tags_html = ''.join(f'<span class="tag">{html.escape(t)}</span>' for t in m["tags"][:6])
        extra = f' +{len(m["tags"])-6}' if len(m["tags"]) > 6 else ''
        style_cls = f'style-{m["style"]}' if m["style"] != "unknown" else "style-unknown"
        size_str = f'{m["size_kb"]:.0f}KB' if m["size_kb"] < 1024 else f'{m["size_kb"]/1024:.1f}MB'
        file_uri = Path(m["path"]).as_uri()
        data_tags = ' '.join(m["tags"])
        html_out.append(f'''
<div class="card" data-tags="{html.escape(data_tags)}" data-style="{html.escape(m['style'])}" data-filename="{html.escape(m['filename'])}" onclick="openModal(this)">
  <div class="img-wrap"><img src="{file_uri}" alt="{html.escape(m['filename'])}" loading="lazy"></div>
  <div class="info">
    <div class="filename" title="{html.escape(m['filename'])}">{html.escape(m['filename'])}</div>
    <span class="style-badge {style_cls}">{html.escape(m['style'])}</span>
    <div class="tags">{tags_html}{html.escape(extra)}</div>
    <div class="size">{size_str}</div>
  </div>
</div>''')
    html_out.append('</div></div>')

# No results notice
html_out.append('<div id="no-results">No memes match your filter 😢</div>')

# Modal
html_out.append('''
<div class="modal-overlay" id="modal" onclick="closeModal()">
  <div class="modal-content" onclick="event.stopPropagation()">
    <button class="modal-close" onclick="closeModal()">&times;</button>
    <img id="modal-img" src="" alt="">
    <div class="modal-caption" id="modal-caption"></div>
  </div>
</div>
''')

# JS
html_out.append('''
<script>
function filterCards() {
  const q = document.getElementById('searchBox').value.toLowerCase();
  const style = document.getElementById('styleFilter').value;
  let visible = 0;
  document.querySelectorAll('.card').forEach(card => {
    const tags = (card.dataset.tags || '').toLowerCase();
    const fn = (card.dataset.filename || '').toLowerCase();
    const st = card.dataset.style || '';
    const matchQ = !q || fn.includes(q) || tags.includes(q);
    const matchS = !style || st === style;
    const show = matchQ && matchS;
    card.style.display = show ? '' : 'none';
    if (show) visible++;
  });
  // Hide empty categories
  document.querySelectorAll('.category').forEach(cat => {
    const cards = cat.querySelectorAll('.card');
    const anyVisible = Array.from(cards).some(c => c.style.display !== 'none');
    cat.style.display = anyVisible ? '' : 'none';
  });
  document.getElementById('no-results').style.display = visible === 0 ? 'block' : 'none';
}
function openModal(card) {
  const img = card.querySelector('img');
  const fn = card.dataset.filename;
  const tags = card.dataset.tags;
  const style = card.dataset.style;
  document.getElementById('modal-img').src = img.src;
  document.getElementById('modal-caption').textContent = fn + ' | ' + style + ' | ' + tags;
  document.getElementById('modal').classList.add('active');
}
function closeModal() {
  document.getElementById('modal').classList.remove('active');
}
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') closeModal();
});
</script>
</body></html>
''')

with open(output_file, 'w') as f:
    f.write('\n'.join(html_out))

print(f"🖼️  Gallery generated: {output_file}")
print(f"   {total} memes | {len(sorted_cats)} categories | {len(all_tags)} tags | {len(all_styles)} styles")
if filter_cat:
    print(f"   Filter: category={filter_cat}")
if filter_style:
    print(f"   Filter: style={filter_style}")
if filter_tag:
    print(f"   Filter: tag={filter_tag}")
PYEOF
}

[[ $# -lt 1 ]] && usage
case "$1" in
  cron-check)      shift; cmd_cron_check "$@" ;;
  retire)          shift; cmd_retire "$@" ;;
  wake)            shift; cmd_wake "$@" ;;
  dormant-blast)   shift; cmd_dormant_blast "$@" ;;
  freshness)       shift; cmd_freshness "$@" ;;
  sync)            cmd_sync ;;
  normalize)       cmd_normalize ;;
  stats)           cmd_stats ;;
  failures)        shift; cmd_failures "$@" ;;
  search)          shift; cmd_search "$@" ;;
  suggest)         shift; cmd_suggest "$@" ;;
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
  lint)       shift; cmd_lint "$@" ;;
  coverage)  shift; cmd_coverage "$@" ;;
  review)    shift; cmd_review "$@" ;;
  dedup)     shift; cmd_dedup "$@" ;;
  gallery)   shift; cmd_gallery "$@" ;;
  -h|--help)      usage ;;
  *)              echo "Unknown command: $1" >&2; usage ;;
esac
