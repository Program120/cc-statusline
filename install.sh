#!/bin/bash
set -e

SCRIPT_URL="https://raw.githubusercontent.com/Program120/cc-statusline/main/statusline.sh"
DEST="$HOME/.claude/statusline.sh"
SETTINGS="$HOME/.claude/settings.json"

echo "📦 Installing cc-statusline..."

# Ensure ~/.claude exists
mkdir -p "$HOME/.claude"

# Download statusline script
if command -v curl &>/dev/null; then
  curl -fsSL "$SCRIPT_URL" -o "$DEST"
elif command -v wget &>/dev/null; then
  wget -qO "$DEST" "$SCRIPT_URL"
else
  echo "❌ curl or wget required"
  exit 1
fi
chmod +x "$DEST"
echo "✅ Script installed to $DEST"

# Check dependencies
for cmd in jq bc; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "⚠️  Missing dependency: $cmd"
    echo "   Install it with: brew install $cmd (macOS) or apt install $cmd (Linux)"
  fi
done

# Configure Claude Code settings
if [ -f "$SETTINGS" ]; then
  if command -v jq &>/dev/null; then
    tmp=$(mktemp)
    jq '.statusLine = {"type": "command", "command": "~/.claude/statusline.sh", "padding": 0}' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    echo "✅ Claude Code settings updated"
  else
    echo "⚠️  Please add the following to $SETTINGS manually:"
    echo '   "statusLine": {"type": "command", "command": "~/.claude/statusline.sh", "padding": 0}'
  fi
else
  cat > "$SETTINGS" << 'EOF'
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 0
  }
}
EOF
  echo "✅ Claude Code settings created"
fi

echo ""
echo "🎉 Done! Restart Claude Code to see the new status line."
