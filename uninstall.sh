#!/bin/bash
set -euo pipefail
umask 077

DEST="${HOME}/.claude/statusline.sh"
SETTINGS="${HOME}/.claude/settings.json"
DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/cc-statusline"
SYSTEMD_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
CACHE_FILE="${CC_STATUSLINE_CACHE_FILE:-${XDG_CACHE_HOME:-${HOME}/.cache}/cc-statusline/codex-quota.json}"
SERVICE_NAME="cc-statusline-codex-quota.service"
TIMER_NAME="cc-statusline-codex-quota.timer"
LAUNCHD_LABEL="com.program120.cc-statusline-codex-quota"
LAUNCHD_PLIST="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
PURGE=0
NO_CONFIG=0

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--no-config] [--purge]

  --no-config  Do not change ~/.claude/settings.json.
  --purge      Also remove the redacted Codex quota cache.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-config) NO_CONFIG=1 ;;
    --purge) PURGE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if command -v systemctl >/dev/null 2>&1 \
  && systemctl --user show-environment >/dev/null 2>&1; then
  systemctl --user disable --now "$TIMER_NAME" >/dev/null 2>&1 || true
  systemctl --user stop "$SERVICE_NAME" >/dev/null 2>&1 || true
fi
rm -f -- "$SYSTEMD_DIR/$SERVICE_NAME" "$SYSTEMD_DIR/$TIMER_NAME"
if command -v systemctl >/dev/null 2>&1 \
  && systemctl --user show-environment >/dev/null 2>&1; then
  systemctl --user daemon-reload
fi

if command -v launchctl >/dev/null 2>&1; then
  launchd_domain="gui/$(id -u)"
  launchctl bootout "$launchd_domain" "$LAUNCHD_PLIST" >/dev/null 2>&1 \
    || launchctl bootout "$launchd_domain/$LAUNCHD_LABEL" >/dev/null 2>&1 \
    || true
fi
rm -f -- "$LAUNCHD_PLIST"

rm -f -- "$DATA_DIR/libexec/codex-quota-refresh.py"
rmdir -- "$DATA_DIR/libexec" "$DATA_DIR" 2>/dev/null || true

if [ "$NO_CONFIG" -eq 0 ] && [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
  if jq -e . "$SETTINGS" >/dev/null 2>&1; then
    configured=$(jq -r '.statusLine.command // empty' "$SETTINGS")
    if [ "$configured" = "bash $DEST" ] || [ "$configured" = "~/.claude/statusline.sh" ]; then
      temporary=$(mktemp "${SETTINGS}.tmp.XXXXXX")
      jq 'del(.statusLine)' "$SETTINGS" >"$temporary"
      chmod --reference="$SETTINGS" "$temporary" 2>/dev/null || chmod 0600 "$temporary"
      mv -f -- "$temporary" "$SETTINGS"
      printf 'Removed matching Claude Code statusLine setting.\n'
    elif [ -n "$configured" ]; then
      printf 'Left non-matching statusLine setting unchanged.\n'
    fi
  else
    printf 'Invalid JSON in %s; leaving it unchanged.\n' "$SETTINGS" >&2
  fi
fi

if [ -f "$DEST" ]; then
  printf 'Left %s in place because its ownership cannot be proven safely.\n' "$DEST"
fi

if [ "$PURGE" -eq 1 ]; then
  rm -f -- "$CACHE_FILE"
  rmdir -- "$(dirname -- "$CACHE_FILE")" 2>/dev/null || true
  printf 'Removed the Codex quota cache.\n'
fi

printf 'Removed the cc-statusline Codex quota refresher.\n'
