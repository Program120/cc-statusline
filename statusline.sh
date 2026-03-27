#!/bin/bash
input=$(cat)

# Extract all metrics
MODEL=$(echo "$input" | jq -r '.model.display_name // "unknown"')
eval "$(echo "$input" | jq -r '
  "CTX_INPUT=\(.context_window.total_input_tokens // 0)",
  "CTX_OUTPUT=\(.context_window.total_output_tokens // 0)",
  "CTX_USED_PCT=\(.context_window.used_percentage // 0 | round)",
  "CACHE_READ=\(.context_window.current_usage.cache_read_input_tokens // 0)",
  "CACHE_WRITE=\(.context_window.current_usage.cache_creation_input_tokens // 0)",
  "INPUT=\(.context_window.current_usage.input_tokens // 0)",
  "OUTPUT=\(.context_window.current_usage.output_tokens // 0)",
  "FIVE_HR_PCT=\(.rate_limits.five_hour.used_percentage // 0 | round)",
  "FIVE_HR_RESET=\(.rate_limits.five_hour.resets_at // 0)",
  "WEEK_PCT=\(.rate_limits.seven_day.used_percentage // 0 | round)",
  "WEEK_RESET=\(.rate_limits.seven_day.resets_at // 0)"
')"

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
  local now=$(date +%s)
  local diff=$((reset_ts - now))
  if [ "$diff" -le 0 ]; then
    echo "now"
  elif [ "$diff" -lt 3600 ]; then
    echo "$((diff / 60))m"
  elif [ "$diff" -lt 86400 ]; then
    echo "$((diff / 3600))h$((diff % 3600 / 60))m"
  else
    echo "$((diff / 86400))d $((diff % 86400 / 3600))hr $((diff % 3600 / 60))m"
  fi
}

CTX_FMT=$(fmt "$((CTX_INPUT + CTX_OUTPUT))")
TOTAL_CACHE=$((CACHE_READ + CACHE_WRITE))
[ "$TOTAL_CACHE" -gt 0 ] && HIT_PCT=$((CACHE_READ * 100 / TOTAL_CACHE)) || HIT_PCT=0
CR=$(fmt "$CACHE_READ"); CW=$(fmt "$CACHE_WRITE")
IN=$(fmt "$INPUT"); OUT=$(fmt "$OUTPUT")
FIVE_REMAIN=$(remaining "$FIVE_HR_RESET")
WEEK_REMAIN=$(remaining "$WEEK_RESET")

# === Colors ===
R="\033[0m"
SEP=""

# Powerline backgrounds
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

# Powerline separator helper: fg=prev_bg, bg=next_bg
sep() { printf "\033[38;5;%sm\033[48;5;%sm%s\033[0m" "$1" "$2" "$SEP"; }
sep_end() { printf "\033[38;5;%sm\033[49m%s\033[0m" "$1" "$SEP"; }

# ── Line 1: Model | Ctx | Ctx% ──
printf "${C_DKRED} Model: ${MODEL} ${R}"; sep 131 220
printf "${C_YELLOW} Ctx: ${CTX_FMT} ${R}"; sep 220 103
printf "${C_PURPLE} Ctx: ${CTX_USED_PCT}%% ${R}"; sep_end 103
printf "\n"

# ── Line 2: Session | Session Reset | Weekly | Weekly Reset ──
printf "${C_DKRED} Session: ${FIVE_HR_PCT}%% ${R}"; sep 131 180
printf "${C_TAN} Reset ~${FIVE_REMAIN} ${R}"; sep 180 220
printf "${C_YELLOW} Weekly: ${WEEK_PCT}%% ${R}"; sep 220 103
printf "${C_PURPLE} Reset ~${WEEK_REMAIN} ${R}"; sep_end 103
printf "\n"

# ── Line 3: Cache | Read | Write | In | Out ──
if [ "$HIT_PCT" -ge 70 ]; then
  BADGE="${C_GREEN}"; BADGE_C=71
elif [ "$HIT_PCT" -ge 40 ]; then
  BADGE="${C_YELLOW}"; BADGE_C=220
else
  BADGE="${C_DKRED}"; BADGE_C=131
fi

printf "${BADGE} Cache %3d%% ${R}" "$HIT_PCT"
printf " ${C_TEAL} Read ${CR} ${R}"
printf " ${C_ORANGE} Write ${CW} ${R}"
printf " ${DIM}|${R}"
printf " ${C_BLUE} In ${IN} ${R}"
printf " ${C_MAUVE} Out ${OUT} ${R}"
printf "\n"
