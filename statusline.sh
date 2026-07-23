#!/bin/bash
umask 077

input=$(cat)
display_input=$input
HIDE_TRANSIENT_USAGE=0

# Keep the last valid usage snapshot per session. Some intermediate Claude Code
# refreshes carry a temporary all-zero context_window; those should not replace
# metrics already observed for that session.
CACHE_SESSION_ID=""
SNAPSHOT_VALID=""
CACHE_SNAPSHOT=""
if cache_meta=$(printf '%s' "$input" | jq -r '
  def positive_number:
    type == "number" and . > 0;
  def valid_snapshot:
    ((.context_window.total_input_tokens | positive_number)
      or ([
        .context_window.current_usage.input_tokens,
        .context_window.current_usage.output_tokens,
        .context_window.current_usage.cache_creation_input_tokens,
        .context_window.current_usage.cache_read_input_tokens
      ] | any(.[]; positive_number))
      or ((.rate_limits.five_hour.used_percentage | type) == "number")
      or ((.rate_limits.seven_day.used_percentage | type) == "number"));
  def metric_snapshot:
    {
      context_window: {
        total_input_tokens: (.context_window.total_input_tokens // null),
        used_percentage: (.context_window.used_percentage // null),
        context_window_size: (
          .context_window.context_window_size
          // .context_window.limit
          // .context_window.capacity
          // .context_window.max_tokens
          // null
        ),
        current_usage: {
          input_tokens: (.context_window.current_usage.input_tokens // null),
          output_tokens: (.context_window.current_usage.output_tokens // null),
          cache_creation_input_tokens: (.context_window.current_usage.cache_creation_input_tokens // null),
          cache_read_input_tokens: (.context_window.current_usage.cache_read_input_tokens // null)
        }
      },
      rate_limits: {
        five_hour: {
          used_percentage: (.rate_limits.five_hour.used_percentage // null),
          resets_at: (.rate_limits.five_hour.resets_at // null)
        },
        seven_day: {
          used_percentage: (.rate_limits.seven_day.used_percentage // null),
          resets_at: (.rate_limits.seven_day.resets_at // null)
        }
      }
    };
  "CACHE_SESSION_ID=\(((.session_id // .sessionId // "") | if type == "string" then . else tostring end) | @sh)",
  "SNAPSHOT_VALID=\((if valid_snapshot then "1" else "0" end) | @sh)",
  "CACHE_SNAPSHOT=\((metric_snapshot | tojson) | @sh)"
' 2>/dev/null); then
  eval "$cache_meta"
fi

CACHE_DIR=""
CACHE_FILE=""
if [ -n "$CACHE_SESSION_ID" ]; then
  # Prefixing the sanitized value keeps even "." and ".." harmless; truncation
  # prevents an unexpected session ID from exceeding filesystem name limits.
  SAFE_SESSION_ID=$(printf '%s' "$CACHE_SESSION_ID" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')
  SAFE_SESSION_ID=${SAFE_SESSION_ID:0:128}
  if [ -n "$SAFE_SESSION_ID" ]; then
    if [ -n "${XDG_CACHE_HOME:-}" ]; then
      CACHE_DIR="${XDG_CACHE_HOME}/cc-statusline"
    elif [ -n "${HOME:-}" ]; then
      CACHE_DIR="${HOME}/.cache/cc-statusline"
    fi
    [ -n "$CACHE_DIR" ] && CACHE_FILE="${CACHE_DIR}/session-${SAFE_SESSION_ID}.json"
  fi
fi

if [ "$SNAPSHOT_VALID" = "1" ] && [ -n "$CACHE_FILE" ]; then
  # The temporary file lives beside its destination so mv is an atomic replace.
  # Every cache operation is best-effort and must never suppress the status line.
  if mkdir -p -- "$CACHE_DIR" 2>/dev/null; then
    CACHE_TMP=$(mktemp "${CACHE_FILE}.tmp.XXXXXX" 2>/dev/null) || CACHE_TMP=""
    if [ -n "$CACHE_TMP" ]; then
      if printf '%s\n' "$CACHE_SNAPSHOT" >"$CACHE_TMP" 2>/dev/null; then
        if ! mv -f -- "$CACHE_TMP" "$CACHE_FILE" 2>/dev/null; then
          rm -f -- "$CACHE_TMP" 2>/dev/null
        fi
      else
        rm -f -- "$CACHE_TMP" 2>/dev/null
      fi
    fi
  fi
elif [ "$SNAPSHOT_VALID" = "0" ]; then
  # With no usable cache, suppress this refresh's synthetic zero context/usage.
  # Rate limits cannot be synthetic here: their presence makes a snapshot valid.
  HIDE_TRANSIENT_USAGE=1
  if [ -n "$CACHE_FILE" ] && [ -r "$CACHE_FILE" ]; then
    if cached_metrics=$(jq -ce '
      def positive_number:
        type == "number" and . > 0;
      def valid_snapshot:
        ((.context_window.total_input_tokens | positive_number)
          or ([
            .context_window.current_usage.input_tokens,
            .context_window.current_usage.output_tokens,
            .context_window.current_usage.cache_creation_input_tokens,
            .context_window.current_usage.cache_read_input_tokens
          ] | any(.[]; positive_number))
          or ((.rate_limits.five_hour.used_percentage | type) == "number")
          or ((.rate_limits.seven_day.used_percentage | type) == "number"));
      select(type == "object" and valid_snapshot)
      | {
          context_window: {
            total_input_tokens: (.context_window.total_input_tokens // null),
            used_percentage: (.context_window.used_percentage // null),
            context_window_size: (.context_window.context_window_size // null),
            current_usage: {
              input_tokens: (.context_window.current_usage.input_tokens // null),
              output_tokens: (.context_window.current_usage.output_tokens // null),
              cache_creation_input_tokens: (.context_window.current_usage.cache_creation_input_tokens // null),
              cache_read_input_tokens: (.context_window.current_usage.cache_read_input_tokens // null)
            }
          },
          rate_limits: {
            five_hour: {
              used_percentage: (.rate_limits.five_hour.used_percentage // null),
              resets_at: (.rate_limits.five_hour.resets_at // null)
            },
            seven_day: {
              used_percentage: (.rate_limits.seven_day.used_percentage // null),
              resets_at: (.rate_limits.seven_day.resets_at // null)
            }
          }
        }
    ' "$CACHE_FILE" 2>/dev/null); then
      # The cache contains only metric branches, so recursive merge preserves the
      # current refresh's model, session metadata, CWD, and every unrelated field.
      if merged_input=$(printf '%s\n%s\n' "$input" "$cached_metrics" | jq -cse '
        if length == 2
          and (.[0] | type) == "object"
          and (.[1] | type) == "object"
        then .[0] * .[1]
        else empty
        end
      ' 2>/dev/null); then
        display_input=$merged_input
        HIDE_TRANSIENT_USAGE=0
      fi
    fi
  fi
fi

# Extract display fields in one jq pass after any cached metrics have been
# merged. Values go through @sh so eval stays safe on spaces, quotes, or $.
MODEL="unknown"
SESSION_ID="unknown"
CWD=""
CTX_INPUT=""
CTX_USED_PCT=""
CTX_CAP=""
HAS_USAGE=0
CACHE_READ=""
CACHE_WRITE=""
INPUT=""
OUTPUT=""
FIVE_HR_PCT=""
FIVE_HR_RESET=""
WEEK_PCT=""
WEEK_RESET=""
if display_fields=$(printf '%s' "$display_input" | jq -r '
  "MODEL=\((.model.display_name // .model.id // "unknown") | @sh)",
  "SESSION_ID=\((.session_id // .sessionId // "unknown") | @sh)",
  "CWD=\((.workspace.current_dir // .cwd // "") | @sh)",
  "CTX_INPUT=\((.context_window.total_input_tokens // "") | @sh)",
  "CTX_USED_PCT=\((.context_window.used_percentage // "") | if type == "number" then round else "" end | @sh)",
  "CTX_CAP=\((.context_window.context_window_size // .context_window.limit // .context_window.capacity // .context_window.max_tokens // "") | @sh)",
  "HAS_USAGE=\((if (.context_window.current_usage | type) == "object" then 1 else 0 end) | @sh)",
  "CACHE_READ=\((.context_window.current_usage.cache_read_input_tokens // "") | @sh)",
  "CACHE_WRITE=\((.context_window.current_usage.cache_creation_input_tokens // "") | @sh)",
  "INPUT=\((.context_window.current_usage.input_tokens // "") | @sh)",
  "OUTPUT=\((.context_window.current_usage.output_tokens // "") | @sh)",
  "FIVE_HR_PCT=\((.rate_limits.five_hour.used_percentage // "") | if type == "number" then round else "" end | @sh)",
  "FIVE_HR_RESET=\((.rate_limits.five_hour.resets_at // "") | @sh)",
  "WEEK_PCT=\((.rate_limits.seven_day.used_percentage // "") | if type == "number" then round else "" end | @sh)",
  "WEEK_RESET=\((.rate_limits.seven_day.resets_at // "") | @sh)"
' 2>/dev/null); then
  eval "$display_fields"
fi

if [ "$HIDE_TRANSIENT_USAGE" = "1" ]; then
  CTX_INPUT=""
  CTX_USED_PCT=""
  HAS_USAGE=0
  CACHE_READ=""
  CACHE_WRITE=""
  INPUT=""
  OUTPUT=""
fi

# Codex quota is refreshed out of band; the per-second statusline path only reads
# the small, redacted cache. Invalid, expired, or very stale snapshots stay hidden.
NOW=$(date +%s)
CODEX_REMAIN_PCT=""
CODEX_RESET=""
CODEX_STALE=0
CODEX_CACHE_FILE="${CC_STATUSLINE_CACHE_FILE:-}"
if [ -z "$CODEX_CACHE_FILE" ]; then
  if [ -n "${XDG_CACHE_HOME:-}" ]; then
    CODEX_CACHE_FILE="${XDG_CACHE_HOME}/cc-statusline/codex-quota.json"
  elif [ -n "${HOME:-}" ]; then
    CODEX_CACHE_FILE="${HOME}/.cache/cc-statusline/codex-quota.json"
  fi
fi
if [ -n "$CODEX_CACHE_FILE" ] && [ -r "$CODEX_CACHE_FILE" ]; then
  if codex_fields=$(jq -er '
    select(
      type == "object"
      and .schema_version == 1
      and (.fetched_at | type) == "number"
      and (.fetched_at | floor) == .fetched_at
      and .fetched_at > 0
      and (.weekly | type) == "object"
      and .weekly.window_duration_mins == 10080
      and (.weekly.remaining_percent | type) == "number"
      and (.weekly.remaining_percent | floor) == .weekly.remaining_percent
      and .weekly.remaining_percent >= 0
      and .weekly.remaining_percent <= 100
      and (.weekly.resets_at | type) == "number"
      and (.weekly.resets_at | floor) == .weekly.resets_at
      and .weekly.resets_at > 0
    )
    | "CODEX_FETCHED_AT=\(.fetched_at | @sh)",
      "CODEX_REMAIN_PCT=\(.weekly.remaining_percent | @sh)",
      "CODEX_RESET=\(.weekly.resets_at | @sh)"
  ' "$CODEX_CACHE_FILE" 2>/dev/null); then
    eval "$codex_fields"
    CODEX_AGE=$((NOW - CODEX_FETCHED_AT))
    if [ "$CODEX_AGE" -lt -60 ] || [ "$CODEX_AGE" -gt 3600 ] || [ "$CODEX_RESET" -le "$NOW" ]; then
      CODEX_REMAIN_PCT=""
      CODEX_RESET=""
    elif [ "$CODEX_AGE" -gt 900 ]; then
      CODEX_STALE=1
    fi
  fi
fi

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

fmt() {
  local n=$1
  if [ "$n" -ge 1000000 ]; then
    printf "%.1fM" "$(echo "scale=1; $n/1000000" | bc)"
  elif [ "$n" -ge 1000 ]; then
    printf "%.1fk" "$(echo "scale=1; $n/1000" | bc)"
  else
    echo "$n"
  fi
}

remaining() {
  local reset_ts=$1
  local diff=$((reset_ts - NOW))
  if [ "$diff" -le 0 ]; then echo "now"
  elif [ "$diff" -lt 3600 ]; then echo "$((diff / 60))m"
  elif [ "$diff" -lt 86400 ]; then echo "$((diff / 3600))h$((diff % 3600 / 60))m"
  else echo "$((diff / 86400))d $((diff % 86400 / 3600))hr $((diff % 3600 / 60))m"
  fi
}

# Context usage is the total input currently occupying the window. Prefer the
# explicit window size when a percentage must be derived; never infer it from
# the model name and never add output tokens to the occupied-token count.
CTX_FMT=""
if is_uint "$CTX_INPUT"; then
  CTX_FMT=$(fmt "$CTX_INPUT")
else
  CTX_INPUT=""
fi
if ! is_uint "$CTX_USED_PCT"; then
  CTX_USED_PCT=""
fi
if [ -z "$CTX_USED_PCT" ] && [ -n "$CTX_INPUT" ] && is_uint "$CTX_CAP" && [ "$CTX_CAP" -gt 0 ]; then
  CTX_USED_PCT=$(( (CTX_INPUT * 100 + CTX_CAP / 2) / CTX_CAP ))
fi

# Missing current_usage fields stay hidden rather than becoming synthetic zeroes.
for usage_var in CACHE_READ CACHE_WRITE INPUT OUTPUT; do
  if ! is_uint "${!usage_var}"; then
    printf -v "$usage_var" '%s' ""
  fi
done

HIT_PCT=""
if [ -n "$INPUT" ] && [ -n "$CACHE_READ" ] && [ -n "$CACHE_WRITE" ]; then
  CACHE_DENOM=$((INPUT + CACHE_READ + CACHE_WRITE))
  if [ "$CACHE_DENOM" -gt 0 ]; then
    HIT_PCT=$((CACHE_READ * 100 / CACHE_DENOM))
  fi
fi

CR=""; CW=""; IN=""; OUT=""
[ -n "$CACHE_READ" ] && CR=$(fmt "$CACHE_READ")
[ -n "$CACHE_WRITE" ] && CW=$(fmt "$CACHE_WRITE")
[ -n "$INPUT" ] && IN=$(fmt "$INPUT")
[ -n "$OUTPUT" ] && OUT=$(fmt "$OUTPUT")

# Missing rate-limit objects or fields stay hidden. A reset is only rendered
# alongside its corresponding limit and only when it is a valid future epoch.
if ! is_uint "$FIVE_HR_PCT"; then FIVE_HR_PCT=""; fi
if ! is_uint "$WEEK_PCT"; then WEEK_PCT=""; fi
if ! is_uint "$CODEX_REMAIN_PCT"; then CODEX_REMAIN_PCT=""; fi
FIVE_REMAIN=""
WEEK_REMAIN=""
CODEX_REMAIN=""
if [ -n "$FIVE_HR_PCT" ] && is_uint "$FIVE_HR_RESET" && [ "$FIVE_HR_RESET" -gt 0 ]; then
  FIVE_REMAIN=$(remaining "$FIVE_HR_RESET")
fi
if [ -n "$WEEK_PCT" ] && is_uint "$WEEK_RESET" && [ "$WEEK_RESET" -gt 0 ]; then
  WEEK_REMAIN=$(remaining "$WEEK_RESET")
fi
if [ -n "$CODEX_REMAIN_PCT" ] && is_uint "$CODEX_RESET" && [ "$CODEX_RESET" -gt "$NOW" ]; then
  CODEX_REMAIN=$(remaining "$CODEX_RESET")
else
  CODEX_REMAIN_PCT=""
fi

# Git branch. Resolve against the session's dir (CWD from jq above), not the
# script's cwd. Detached HEAD falls back to a short sha, prefixed with @.
BRANCH=""
if [ -n "$CWD" ]; then
  BRANCH=$(GIT_OPTIONAL_LOCKS=0 git -C "$CWD" symbolic-ref --quiet --short HEAD 2>/dev/null)
  if [ -z "$BRANCH" ]; then
    SHA=$(GIT_OPTIONAL_LOCKS=0 git -C "$CWD" rev-parse --short HEAD 2>/dev/null)
    [ -n "$SHA" ] && BRANCH="@${SHA}"
  fi
fi

# === Colors ===
R="\033[0m"
SEP=""

C_DKRED="\033[38;5;231m\033[48;5;131m"
C_YELLOW="\033[38;5;16m\033[48;5;220m"
C_PURPLE="\033[38;5;231m\033[48;5;103m"
C_GREEN="\033[38;5;16m\033[48;5;71m"
C_TEAL="\033[38;5;16m\033[48;5;109m"
C_ORANGE="\033[38;5;16m\033[48;5;173m"
C_BLUE="\033[38;5;16m\033[48;5;67m"
C_MAUVE="\033[38;5;16m\033[48;5;139m"
C_TAN="\033[38;5;16m\033[48;5;180m"
DIM="\033[2m"

sep() { printf "\033[38;5;%sm\033[48;5;%sm%s\033[0m" "$1" "$2" "$SEP"; }
sep_end() { printf "\033[38;5;%sm\033[49m%s\033[0m" "$1" "$SEP"; }

# ── Line 1: Model | Ctx tokens | Ctx % | Branch ──
printf "${C_DKRED} Model: %s ${R}" "$MODEL"
LAST_BG=131
if [ -n "$CTX_FMT" ]; then
  sep "$LAST_BG" 220
  printf "${C_YELLOW} Ctx: %s ${R}" "$CTX_FMT"
  LAST_BG=220
fi
if [ -n "$CTX_USED_PCT" ]; then
  sep "$LAST_BG" 103
  printf "${C_PURPLE} Ctx: %s%% ${R}" "$CTX_USED_PCT"
  LAST_BG=103
fi
if [ -n "$BRANCH" ]; then
  sep "$LAST_BG" 71
  printf "${C_GREEN}  %s ${R}" "$BRANCH"
  LAST_BG=71
fi
sep_end "$LAST_BG"
printf "\n"

# ── Line 2: Session | Reset | Weekly | Reset ──
RATE_PRINTED=0
RATE_BG=""
if [ -n "$FIVE_HR_PCT" ]; then
  printf "${C_DKRED} Session: %s%% ${R}" "$FIVE_HR_PCT"
  RATE_PRINTED=1
  RATE_BG=131
  if [ -n "$FIVE_REMAIN" ]; then
    sep "$RATE_BG" 180
    printf "${C_TAN} Reset ~%s ${R}" "$FIVE_REMAIN"
    RATE_BG=180
  fi
fi
if [ -n "$WEEK_PCT" ]; then
  if [ "$RATE_PRINTED" -eq 1 ]; then
    sep "$RATE_BG" 220
  fi
  printf "${C_YELLOW} Weekly: %s%% ${R}" "$WEEK_PCT"
  RATE_PRINTED=1
  RATE_BG=220
  if [ -n "$WEEK_REMAIN" ]; then
    sep "$RATE_BG" 103
    printf "${C_PURPLE} Reset ~%s ${R}" "$WEEK_REMAIN"
    RATE_BG=103
  fi
fi
if [ -n "$CODEX_REMAIN_PCT" ]; then
  if [ "$RATE_PRINTED" -eq 1 ]; then
    sep "$RATE_BG" 109
  fi
  if [ "$CODEX_STALE" -eq 1 ]; then
    printf "${C_TEAL} Codex W*: %s%% left ${R}" "$CODEX_REMAIN_PCT"
  else
    printf "${C_TEAL} Codex W: %s%% left ${R}" "$CODEX_REMAIN_PCT"
  fi
  RATE_PRINTED=1
  RATE_BG=109
  if [ -n "$CODEX_REMAIN" ]; then
    sep "$RATE_BG" 180
    printf "${C_TAN} Reset ~%s ${R}" "$CODEX_REMAIN"
    RATE_BG=180
  fi
fi
if [ "$RATE_PRINTED" -eq 1 ]; then
  sep_end "$RATE_BG"
  printf "\n"
fi

# ── Line 3: Cache | Read | Write | In | Out ──
if [ "$HAS_USAGE" = "1" ]; then
  LINE3_PRINTED=0
  CACHE_SIDE_PRINTED=0

  if [ -n "$HIT_PCT" ]; then
    if [ "$HIT_PCT" -ge 70 ]; then
      BADGE="${C_GREEN}"
    elif [ "$HIT_PCT" -ge 40 ]; then
      BADGE="${C_YELLOW}"
    else
      BADGE="${C_DKRED}"
    fi
    printf "${BADGE} Cache %3d%% ${R}" "$HIT_PCT"
    LINE3_PRINTED=1
    CACHE_SIDE_PRINTED=1
  fi
  if [ -n "$CR" ]; then
    [ "$LINE3_PRINTED" -eq 1 ] && printf " "
    printf "${C_TEAL} Read %s ${R}" "$CR"
    LINE3_PRINTED=1
    CACHE_SIDE_PRINTED=1
  fi
  if [ -n "$CW" ]; then
    [ "$LINE3_PRINTED" -eq 1 ] && printf " "
    printf "${C_ORANGE} Write %s ${R}" "$CW"
    LINE3_PRINTED=1
    CACHE_SIDE_PRINTED=1
  fi

  if [ -n "$IN" ] || [ -n "$OUT" ]; then
    if [ "$CACHE_SIDE_PRINTED" -eq 1 ]; then
      printf " ${DIM}|${R}"
    fi
    if [ -n "$IN" ]; then
      [ "$LINE3_PRINTED" -eq 1 ] && printf " "
      printf "${C_BLUE} In %s ${R}" "$IN"
      LINE3_PRINTED=1
    fi
    if [ -n "$OUT" ]; then
      [ "$LINE3_PRINTED" -eq 1 ] && printf " "
      printf "${C_MAUVE} Out %s ${R}" "$OUT"
      LINE3_PRINTED=1
    fi
  fi

  [ "$LINE3_PRINTED" -eq 1 ] && printf "\n"
fi

# ── Line 4: Session ID ──
printf "${C_MAUVE} Session: %s ${R}" "$SESSION_ID"
sep_end 139
printf "\n"
