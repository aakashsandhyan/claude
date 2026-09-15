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
#   CLAUDE_CACHE_TTL   cache TTL in seconds (default 3600; use 300 for the 5m tier)
#   BAR_WIDTH          context bar width in chars (default 10)
#   NO_COLOR           set to any value to disable ANSI colour
#
# Idle time is derived from the transcript file's mtime, since the statusLine
# JSON carries no last-interaction timestamp. Two known limits:
#   - The status line re-renders on conversation activity, not on a timer, so
#     the idle counter does not tick while you are away; it corrects on the
#     next turn.
#   - mtime marks the end of a turn, while the cache clock starts at the
#     request's beginning. Negligible against a 1h TTL, material against 5m.

input=$(cat)

TTL="${CLAUDE_CACHE_TTL:-3600}"
BAR_WIDTH="${BAR_WIDTH:-10}"

MODEL=$(jq -r '.model.display_name // "?"' <<< "$input")
DIR=$(basename "$(jq -r '.workspace.current_dir // .cwd // "."' <<< "$input")")
TRANSCRIPT=$(jq -r '.transcript_path // ""' <<< "$input")

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
  [[ "$TOK" != "-" ]] && CTX+=" $(human "$TOK")"
else
  CTX="ctx ?"
fi

# --- idle + cache ------------------------------------------------------------
if [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
  LAST=$(stat -c %Y "$TRANSCRIPT" 2>/dev/null || stat -f %m "$TRANSCRIPT" 2>/dev/null)
fi

if [[ -n "${LAST:-}" ]]; then
  AGE=$(( $(date +%s) - LAST ))
  (( AGE < 0 )) && AGE=0          # future mtime: clock skew, NFS, VM drift
  IDLE=$(printf '%dm%02ds' $(( AGE / 60 )) $(( AGE % 60 )))
  if (( AGE < TTL )); then
    LEFT=$(( TTL - AGE ))
    if (( LEFT >= 60 )); then CACHE=$(printf 'warm %dm' $(( LEFT / 60 )))
    else                      CACHE=$(printf 'warm %ds' "$LEFT"); fi
  else
    CACHE="cold"
  fi
else
  IDLE="?"; CACHE="?"
fi

printf '[%s] %s · %s · idle %s · cache %s' "$MODEL" "$DIR" "$CTX" "$IDLE" "$CACHE"
