#!/usr/bin/env bash
# Claude Monitor — uninstaller (for installs done via install.sh)
set -euo pipefail

echo "Uninstalling Claude Monitor..."

# Kill running instance
pkill -f "claude_monitor/menubar.py" 2>/dev/null && echo "Stopped running instance." || true
rm -f "$HOME/.claude_monitor.pid"

# Remove install dir + venv
if [ -d "$HOME/.claude_monitor" ]; then
  rm -rf "$HOME/.claude_monitor"
  echo "Removed ~/.claude_monitor"
fi

# Remove launcher
for dir in "$(brew --prefix 2>/dev/null)/bin" /usr/local/bin; do
  [ -f "$dir/claude-monitor" ] && rm -f "$dir/claude-monitor" && echo "Removed $dir/claude-monitor"
done

echo "Done."
