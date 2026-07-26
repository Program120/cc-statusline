#!/bin/bash
set -euo pipefail
umask 077

REPO="Program120/cc-statusline"
REF="${CC_STATUSLINE_REF:-main}"
RAW_BASE="${CC_STATUSLINE_RAW_BASE:-https://raw.githubusercontent.com/${REPO}/${REF}}"
DEST="${HOME}/.claude/statusline.sh"
SETTINGS="${HOME}/.claude/settings.json"
DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/cc-statusline"
HELPER_DEST="${DATA_DIR}/libexec/codex-quota-refresh.py"
SYSTEMD_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
SERVICE_NAME="cc-statusline-codex-quota.service"
TIMER_NAME="cc-statusline-codex-quota.timer"
LAUNCHD_LABEL="com.program120.cc-statusline-codex-quota"
LAUNCHD_DIR="${HOME}/Library/LaunchAgents"
LAUNCHD_PLIST="${LAUNCHD_DIR}/${LAUNCHD_LABEL}.plist"
CACHE_FILE="${CC_STATUSLINE_CACHE_FILE:-${XDG_CACHE_HOME:-${HOME}/.cache}/cc-statusline/codex-quota.json}"
NO_CONFIG=0

usage() {
  cat <<'EOF'
Usage: install.sh [--no-config]

  --no-config  Install files and the quota refresher without changing
               ~/.claude/settings.json (recommended for CC Switch users).
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-config) NO_CONFIG=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

for cmd in jq bc; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'Missing required dependency: %s\n' "$cmd" >&2
    exit 1
  fi
done

fetch() {
  local url=$1 destination=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$destination"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$destination" "$url"
  else
    printf 'curl or wget is required\n' >&2
    return 1
  fi
}

atomic_install() {
  local source=$1 destination=$2 mode=$3 temporary
  mkdir -p -- "$(dirname -- "$destination")"
  temporary=$(mktemp "${destination}.tmp.XXXXXX")
  cp -- "$source" "$temporary"
  chmod "$mode" "$temporary"
  mv -f -- "$temporary" "$destination"
}

resolve_codex() {
  local candidate candidate_dir
  if [ -n "${CODEX_BIN:-}" ]; then
    candidate=$CODEX_BIN
  elif candidate=$(command -v codex 2>/dev/null); then
    :
  elif [ -x "${HOME}/.npm-global/bin/codex" ]; then
    candidate="${HOME}/.npm-global/bin/codex"
  elif [ -x "${HOME}/.local/bin/codex" ]; then
    candidate="${HOME}/.local/bin/codex"
  else
    return 1
  fi
  [ -f "$candidate" ] && [ -x "$candidate" ] || return 1
  candidate_dir=$(cd -P -- "$(dirname -- "$candidate")" && pwd)
  printf '%s/%s\n' "$candidate_dir" "$(basename -- "$candidate")"
}

systemd_escape_value() {
  local value=$1
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//%/%%}
  printf '%s' "$value"
}

install_launchagent() {
  local node_path launchd_path launchd_domain

  if ! command -v plutil >/dev/null 2>&1; then
    printf 'Warning: plutil is unavailable; automatic quota refresh was skipped.\n' >&2
    return
  fi

  node_path=$(command -v node 2>/dev/null || true)
  launchd_path="$(dirname -- "$CODEX_PATH"):$(dirname -- "${node_path:-/usr/bin/node}"):$(dirname -- "$PYTHON_PATH"):/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  if ! python3 - "$staging/launchd.plist.in" "$staging/launchd.plist" \
    "$PYTHON_PATH" "$HELPER_DEST" "$CODEX_PATH" "$CACHE_FILE" \
    "$HOME" "$launchd_path" "${CODEX_HOME:-}" <<'PY'
import os
from pathlib import Path
import plistlib
import sys

(source, target, python_bin, helper, codex_bin, cache, home, path, codex_home) = sys.argv[1:]

def absolute(value: str) -> str:
    return os.path.abspath(os.path.expanduser(value))

with Path(source).open("rb") as input_file:
    data = plistlib.load(input_file)
cache = absolute(cache)
data["ProgramArguments"] = [absolute(python_bin), absolute(helper), "--cache-file", cache]
environment = {
    "CODEX_BIN": absolute(codex_bin),
    "HOME": absolute(home),
    "PATH": path,
}
if codex_home:
    environment["CODEX_HOME"] = absolute(codex_home)
data["EnvironmentVariables"] = environment
with Path(target).open("wb") as output_file:
    plistlib.dump(data, output_file, fmt=plistlib.FMT_XML, sort_keys=False)
PY
  then
    printf 'Warning: the LaunchAgent could not be generated; automatic quota refresh was skipped.\n' >&2
    return
  fi
  if ! plutil -lint "$staging/launchd.plist" >/dev/null; then
    printf 'Warning: generated LaunchAgent is invalid; automatic quota refresh was skipped.\n' >&2
    return
  fi

  launchd_domain="gui/$(id -u)"
  if command -v launchctl >/dev/null 2>&1; then
    launchctl bootout "$launchd_domain" "$LAUNCHD_PLIST" >/dev/null 2>&1 \
      || launchctl bootout "$launchd_domain/$LAUNCHD_LABEL" >/dev/null 2>&1 \
      || true
  fi
  atomic_install "$staging/launchd.plist" "$LAUNCHD_PLIST" 0644

  if ! command -v launchctl >/dev/null 2>&1; then
    printf 'Warning: launchctl is unavailable; the LaunchAgent will load at the next login.\n' >&2
    return
  fi
  launchctl enable "$launchd_domain/$LAUNCHD_LABEL" >/dev/null 2>&1 || true
  if launchctl bootstrap "$launchd_domain" "$LAUNCHD_PLIST"; then
    printf 'Enabled Codex quota refresh LaunchAgent.\n'
  else
    printf 'Warning: launchd quota setup failed; the agent will retry at login. Use the manual refresh command below for now.\n' >&2
  fi
}

PLATFORM=$(uname -s)
CODEX_PATH=""
PYTHON_PATH=""
printf 'Installing cc-statusline...\n'
mkdir -p -- "${HOME}/.claude" "$DATA_DIR/libexec"
staging=$(mktemp -d "${TMPDIR:-/tmp}/cc-statusline-install.XXXXXX")
trap 'rm -rf -- "$staging"' EXIT

fetch "${RAW_BASE}/statusline.sh" "$staging/statusline.sh"
fetch "${RAW_BASE}/libexec/codex-quota-refresh.py" "$staging/codex-quota-refresh.py"
if [ "$PLATFORM" = "Linux" ]; then
  fetch "${RAW_BASE}/systemd/cc-statusline-codex-quota.service.in" "$staging/service.in"
  fetch "${RAW_BASE}/systemd/cc-statusline-codex-quota.timer" "$staging/timer"
elif [ "$PLATFORM" = "Darwin" ]; then
  fetch "${RAW_BASE}/launchd/${LAUNCHD_LABEL}.plist.in" "$staging/launchd.plist.in"
fi

bash -n "$staging/statusline.sh"
if command -v python3 >/dev/null 2>&1; then
  python3 -m py_compile "$staging/codex-quota-refresh.py"
fi

atomic_install "$staging/statusline.sh" "$DEST" 0755
atomic_install "$staging/codex-quota-refresh.py" "$HELPER_DEST" 0755
printf 'Installed statusline: %s\n' "$DEST"

if command -v python3 >/dev/null 2>&1 && CODEX_PATH=$(resolve_codex); then
  PYTHON_PATH=$(command -v python3)
  if [ "$PLATFORM" = "Linux" ] \
    && command -v systemctl >/dev/null 2>&1 \
    && systemctl --user show-environment >/dev/null 2>&1; then
    python_escaped=$(systemd_escape_value "$PYTHON_PATH")
    codex_escaped=$(systemd_escape_value "$CODEX_PATH")
    helper_escaped=$(systemd_escape_value "$HELPER_DEST")
    cache_escaped=$(systemd_escape_value "$CACHE_FILE")
    python3 - "$staging/service.in" "$staging/service" \
      "$python_escaped" "$codex_escaped" "$helper_escaped" "$cache_escaped" <<'PY'
from pathlib import Path
import sys
source, target, python_bin, codex_bin, helper, cache = sys.argv[1:]
text = Path(source).read_text(encoding="utf-8")
text = text.replace("@PYTHON_BIN@", python_bin)
text = text.replace("@CODEX_BIN@", codex_bin)
text = text.replace("@HELPER_PATH@", helper)
text = text.replace("@CACHE_FILE@", cache)
Path(target).write_text(text, encoding="utf-8")
PY
    atomic_install "$staging/service" "$SYSTEMD_DIR/$SERVICE_NAME" 0644
    atomic_install "$staging/timer" "$SYSTEMD_DIR/$TIMER_NAME" 0644
    if systemctl --user daemon-reload \
      && systemctl --user enable --now "$TIMER_NAME" \
      && systemctl --user start "$SERVICE_NAME"; then
      printf 'Enabled Codex quota refresh timer.\n'
    else
      printf 'Warning: systemd quota setup failed; use the manual refresh command below.\n' >&2
    fi
  elif [ "$PLATFORM" = "Darwin" ]; then
    install_launchagent
  elif [ "$PLATFORM" = "Linux" ]; then
    printf 'User systemd is unavailable; automatic quota refresh was skipped.\n'
  else
    printf 'Automatic quota refresh is unsupported on %s; use the manual refresh command below.\n' "$PLATFORM"
  fi
else
  printf 'Python 3 or Codex was not found; the Codex quota segment will stay hidden.\n'
fi

if [ "$NO_CONFIG" -eq 0 ]; then
  desired_command="bash ${DEST}"
  if [ -f "$SETTINGS" ]; then
    if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
      printf 'Invalid JSON in %s; leaving it unchanged.\n' "$SETTINGS" >&2
      exit 1
    fi
    existing_command=$(jq -r '.statusLine.command // empty' "$SETTINGS")
    if [ -n "$existing_command" ] \
      && [ "$existing_command" != "$desired_command" ] \
      && [ "$existing_command" != "~/.claude/statusline.sh" ]; then
      printf 'Existing third-party statusLine left unchanged. Re-run with --no-config and configure it manually.\n' >&2
      exit 1
    fi
    settings_tmp=$(mktemp "${SETTINGS}.tmp.XXXXXX")
    jq --arg command "$desired_command" \
      '.statusLine = {type: "command", command: $command, padding: 0, refreshInterval: 1}' \
      "$SETTINGS" >"$settings_tmp"
    chmod --reference="$SETTINGS" "$settings_tmp" 2>/dev/null || chmod 0600 "$settings_tmp"
    mv -f -- "$settings_tmp" "$SETTINGS"
  else
    mkdir -p -- "$(dirname -- "$SETTINGS")"
    settings_tmp=$(mktemp "${SETTINGS}.tmp.XXXXXX")
    jq -n --arg command "$desired_command" \
      '{statusLine: {type: "command", command: $command, padding: 0, refreshInterval: 1}}' \
      >"$settings_tmp"
    chmod 0600 "$settings_tmp"
    mv -f -- "$settings_tmp" "$SETTINGS"
  fi
  printf 'Updated Claude Code settings: %s\n' "$SETTINGS"
else
  printf 'Skipped Claude Code settings (--no-config).\n'
fi

if [ -n "$CODEX_PATH" ] && [ -n "$PYTHON_PATH" ]; then
  printf 'Manual quota refresh:\n  CODEX_BIN=%q %q %q --cache-file %q\n' \
    "$CODEX_PATH" "$PYTHON_PATH" "$HELPER_DEST" "$CACHE_FILE"
fi
printf 'StatusLine snippet:\n'
printf '  {"type":"command","command":"bash %s","padding":0,"refreshInterval":1}\n' "$DEST"
printf 'Restart Claude Code to use the updated status line.\n'
