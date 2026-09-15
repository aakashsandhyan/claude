#!/bin/bash
# Claude Code status line, three fixed lines:
#
#   [Opus] bahikhaata (main)
#   ██████░░░░ 68% 136k
#   cache warm 47:18 · 1h · hit 91%
#
# Install:
#   chmod +x statusline.sh && cp statusline.sh ~/.claude/statusline.sh
#   # ~/.claude/settings.json:
#   { "statusLine": { "type": "command", "command": "bash ~/.claude/statusline.sh",
#                     "padding": 0, "refreshInterval": 1 } }
#
# refreshInterval (>= 2.1.97) is what makes the countdown tick; without it the
# status line only re-renders on conversation events. Claude Code also re-runs
# the command when a warm cache reaches its expires_at, so the cold transition
# shows up even with refreshInterval unset.
#
# Requires: jq. Cache fields require Claude Code >= 2.1.251
# (last_miss_cause >= 2.1.260); the cache line degrades to "cache -" below that.
#
# Env:
#   BAR_WIDTH   context bar width in chars (default 10)
#   NO_COLOR    set to any value to disable ANSI colour

input=$(cat)
BAR_WIDTH="${BAR_WIDTH:-10}"

# One jq call: at refreshInterval 1 the ~2.5ms process spawn dominates this
# script. Tab-separated so paths containing spaces survive the read.
IFS=$'\t' read -r MODEL CWD PCT TOK CWARM CTTL CEXP CHIT CMISS < <(jq -Rsr '
  (fromjson? // {})                                                      as $j
  | ($j.context_window // {})                                            as $c
  | ($c.current_usage // {})                                             as $u
  | (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0)
     + ($u.cache_read_input_tokens // 0))                                as $usum
  | ($c.total_input_tokens // (if $usum > 0 then $usum else null end))    as $tok
  | ($c.context_window_size // null)                                     as $win
  | ($c.used_percentage //
     (if ($tok != null and $win != null and $win > 0)
      then ($tok / $win * 100) else null end))                           as $pct
  | ($j.prompt_cache // {})                                              as $p
  | [ ($j.model.display_name // "?"),
      ($j.workspace.current_dir // $j.cwd // "."),
      ($pct // "-"), ($tok // "-"),
      (if $p.warm == null then "-" else ($p.warm|tostring) end),
      ($p.ttl // "-"),
      ($p.expires_at // "-"),
      (if $p.hit_ratio == null then "-" else (($p.hit_ratio * 100)|floor|tostring) end),
      (($p.last_miss_cause.causes // []) | join(",") | if . == "" then "-" else . end)
    ] | @tsv
' <<< "$input")
DIR=$(basename "$CWD")

human() { local n=$1
  if   [[ ! "$n" =~ ^[0-9]+$ ]]; then printf -- '-'
  elif (( n >= 1000000 )); then printf '%dM' $(( n / 1000000 ))
  elif (( n >= 1000 ));    then printf '%dk' $(( n / 1000 ))
  else printf '%d' "$n"; fi; }

col() { [[ -n "${NO_COLOR:-}" ]] && printf '%s' "$2" || printf '\033[%sm%s\033[0m' "$1" "$2"; }

# --- line 1: model, dir, branch ----------------------------------------------
# --no-optional-locks keeps this read-only so it cannot contend for
# .git/index.lock on a render path. -C "$CWD" matters: the docs' examples rely
# on the script's own cwd, which is not guaranteed to be the session directory.
LOC="$DIR"
if BRANCH=$(git -C "$CWD" --no-optional-locks branch --show-current 2>/dev/null); then
  [[ -z "$BRANCH" ]] && { SHA=$(git -C "$CWD" --no-optional-locks rev-parse --short HEAD 2>/dev/null); [[ -n "$SHA" ]] && BRANCH="@$SHA"; }
  [[ -n "$BRANCH" ]] && LOC="$DIR ($BRANCH)"
fi

# --- line 2: context bar -----------------------------------------------------
# used_percentage counts input only (input + cache_creation + cache_read), never
# output_tokens -- the manual fallback above uses the same formula so the two
# agree instead of drifting apart.
if [[ "$PCT" != "-" ]]; then
  P=$(printf '%.0f' "$PCT"); (( P < 0 )) && P=0; (( P > 100 )) && P=100
  FILLED=$(( P * BAR_WIDTH / 100 )); BAR=""
  for (( i = 0; i < BAR_WIDTH; i++ )); do (( i < FILLED )) && BAR+="█" || BAR+="░"; done
  if   (( P >= 90 )); then BC=31; elif (( P >= 70 )); then BC=33; else BC=32; fi
  CTX="$(col $BC "$BAR $P%")"
  [[ "$TOK" != "-" ]] && CTX+=" $(human "$TOK")"
else
  CTX="ctx ?"
fi

# --- line 3: prompt cache ----------------------------------------------------
# Straight from the statusLine payload -- Claude Code computes these from the
# API's cache token counts, so there is no transcript to parse and no guessing
# from idle time.
if [[ "$CWARM" == "true" && "$CEXP" =~ ^[0-9]+$ ]]; then
  R=$(( CEXP - $(date +%s) ))
  if (( R > 0 )); then
    if   (( R <= 300 )); then WC=31; elif (( R <= 900 )); then WC=33; else WC=32; fi
    LINE3="$(col $WC "$(printf 'cache warm %d:%02d' $(( R / 60 )) $(( R % 60 )))")"
  else
    LINE3="$(col 31 'cache expiring')"
  fi
  [[ "$CTTL"  != "-" ]] && LINE3+=" · $CTTL"
  [[ "$CHIT"  != "-" ]] && LINE3+=" · hit ${CHIT}%"
elif [[ "$CWARM" == "false" ]]; then
  LINE3="$(col 31 'cache cold')"
  [[ "$CHIT"  != "-" ]] && LINE3+=" · hit ${CHIT}%"
  # Why the last miss happened: tools_changed, system_prompt_changed,
  # ttl_expired_5m, likely_server_side. A non-TTL cause means the prefix moved,
  # which no amount of returning sooner would have fixed.
  [[ "$CMISS" != "-" ]] && LINE3+=" · $(col 33 "$CMISS")"
else
  LINE3="cache -"
fi

printf '[%s] %s\n%s\n%s' "$MODEL" "$LOC" "$CTX" "$LINE3"
