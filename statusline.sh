#!/bin/bash
# Claude Code status line: model, dir, context bar, idle time, prompt-cache warmth.
#
# Install:
#   chmod +x statusline.sh && cp statusline.sh ~/.claude/statusline.sh
#   # ~/.claude/settings.json:
#   { "statusLine": { "type": "command", "command": "~/.claude/statusline.sh", "padding": 0 } }
#
# Requires: jq
#
# Env:
#   CLAUDE_CACHE_TTL   cache TTL in seconds (default 3600; use 300 for the 5m
#                      tier). Only tints the idle figure: yellow past 3/4 of the
#                      TTL, red once the cache has expired.
#   BAR_WIDTH          context bar width in chars (default 10)
#   NO_COLOR           set to any value to disable ANSI colour
#   STATUSLINE_COLS    force a width in columns (overrides auto-detect)
#
# Idle time is derived from the transcript file's mtime, since the statusLine
# JSON carries no last-interaction timestamp. Two known limits:
#   - The status line re-renders on conversation activity, not on a timer, so
#     the idle counter does not tick while you are away; it corrects on the
#     next turn.
#   - mtime marks the end of a turn, while the cache clock starts at the
#     request's beginning. Negligible against a 1h TTL, material against 5m.
#
# Segments wrap onto extra lines when the terminal is too narrow. Because the
# status line only re-renders on conversation activity, a resize does not
# reflow until your next turn.

input=$(cat)

TTL="${CLAUDE_CACHE_TTL:-3600}"
BAR_WIDTH="${BAR_WIDTH:-10}"

MODEL=$(jq -r '.model.display_name // "?"' <<< "$input")
CWD=$(jq -r '.workspace.current_dir // .cwd // "."' <<< "$input")
DIR=$(basename "$CWD")
TRANSCRIPT=$(jq -r '.transcript_path // ""' <<< "$input")

# --- git branch --------------------------------------------------------------
# --no-optional-locks keeps this read-only, so it cannot fight Claude Code or
# your shell over .git/index.lock. Falls back to a short SHA on detached HEAD,
# and to nothing at all outside a repo.
LOC="$DIR"
if BRANCH=$(git -C "$CWD" --no-optional-locks branch --show-current 2>/dev/null); then
  if [[ -z "$BRANCH" ]]; then
    SHA=$(git -C "$CWD" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
    [[ -n "$SHA" ]] && BRANCH="@$SHA"
  fi
  [[ -n "$BRANCH" ]] && LOC="$DIR ($BRANCH)"
fi

# --- context -----------------------------------------------------------------
# Field layout has varied across Claude Code versions. Prefer the server-computed
# used_percentage; fall back to total_input_tokens, then to summing the
# current_usage subtotals, then give up rather than printing a wrong number.
read -r PCT TOK WIN < <(jq -r '
  (.context_window // {})                                              as $c
  | ($c.current_usage // {})                                           as $u
  | (if ($u|type) == "object" then ([$u[] | numbers] | add) else $u end) as $usum
  | ($c.total_input_tokens // $usum)                                   as $tok
  | ($c.context_window_size // null)                                   as $win
  | ($c.used_percentage //
     (if ($tok != null and $win != null and $win > 0)
      then ($tok / $win * 100) else null end))                         as $pct
  | [ ($pct // "-"), ($tok // "-"), ($win // "-") ] | @tsv
' <<< "$input")

human() { # 15420 -> 15k
  local n=$1
  if   [[ "$n" == "-" ]]; then printf -- '-'
  elif (( n >= 1000000 )); then printf '%dM' $(( n / 1000000 ))
  elif (( n >= 1000 ));    then printf '%dk' $(( n / 1000 ))
  else printf '%d' "$n"; fi
}

if [[ "$PCT" != "-" ]]; then
  P=$(printf '%.0f' "$PCT")
  (( P < 0 )) && P=0
  (( P > 100 )) && P=100
  FILLED=$(( P * BAR_WIDTH / 100 ))
  BAR=""
  for (( i = 0; i < BAR_WIDTH; i++ )); do
    if (( i < FILLED )); then BAR+="█"; else BAR+="░"; fi
  done

  if [[ -z "${NO_COLOR:-}" ]]; then
    if   (( P >= 90 )); then C=$'\033[31m'   # red
    elif (( P >= 70 )); then C=$'\033[33m'   # yellow
    else                     C=$'\033[32m'   # green
    fi
    R=$'\033[0m'
  else
    C=""; R=""
  fi
  CTX="${C}${BAR} ${P}%${R}"
  CTX_W=$(( BAR_WIDTH + ${#P} + 2 ))          # bar + space + "NN" + "%"
  if [[ "$TOK" != "-" ]]; then
    H=$(human "$TOK"); CTX+=" $H"; CTX_W=$(( CTX_W + ${#H} + 1 ))
  fi
else
  CTX="ctx ?"; CTX_W=5
fi

# --- idle + cache ------------------------------------------------------------
if [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
  LAST=$(stat -c %Y "$TRANSCRIPT" 2>/dev/null || stat -f %m "$TRANSCRIPT" 2>/dev/null)
fi

if [[ -n "${LAST:-}" ]]; then
  AGE=$(( $(date +%s) - LAST ))
  (( AGE < 0 )) && AGE=0          # future mtime: clock skew, NFS, VM drift
  IDLE=$(printf '%dm%02ds' $(( AGE / 60 )) $(( AGE % 60 )))
  IDLE_PLAIN="$IDLE"
  # Colour carries the cache boundary, so it needs no segment of its own.
  if [[ -z "${NO_COLOR:-}" ]]; then
    if (( AGE >= TTL )); then IDLE=$'\033[31m'"$IDLE"$'\033[0m'        # cold
    elif (( AGE >= TTL * 3 / 4 )); then IDLE=$'\033[33m'"$IDLE"$'\033[0m'  # expiring
    fi
  fi
else
  IDLE="?"; IDLE_PLAIN="?"
fi
IDLE_W=$(( ${#IDLE_PLAIN} + 5 ))   # "idle " + text; measured before colouring

# --- layout ------------------------------------------------------------------
# stdout is a pipe, so `tput cols` reports terminfo's default rather than the
# real window. /dev/tty is the only source of the actual size.
if [[ -n "${STATUSLINE_COLS:-}" ]]; then
  COLS="$STATUSLINE_COLS"
else
  COLS=$(stty size </dev/tty 2>/dev/null | cut -d" " -f2)
  [[ "$COLS" =~ ^[0-9]+$ ]] || COLS=$(tput cols 2>/dev/null)
  [[ "$COLS" =~ ^[0-9]+$ ]] || COLS="${COLUMNS:-80}"
fi
(( COLS -= 2 ))                       # margin for padding / edge glyphs
(( COLS < 20 )) && COLS=20

# Parallel arrays: rendered segment, and its display width. Widths are computed
# rather than measured, because ${#s} counts bytes in a non-UTF-8 locale and the
# bar glyphs are 3 bytes each.
SEGS=(  "[$MODEL] $LOC"        "$CTX"   "idle $IDLE"  )
WIDTH=( $(( ${#MODEL} + ${#LOC} + 3 )) "$CTX_W" "$IDLE_W" )

LINE=""; LW=0; OUT=""
for i in "${!SEGS[@]}"; do
  w=${WIDTH[$i]}
  if (( LW == 0 )); then
    LINE="${SEGS[$i]}"; LW=$w
  elif (( LW + 3 + w <= COLS )); then
    LINE+=" · ${SEGS[$i]}"; LW=$(( LW + 3 + w ))
  else
    OUT+="$LINE"$'\n'; LINE="${SEGS[$i]}"; LW=$w
  fi
done
printf '%s%s' "$OUT" "$LINE"
