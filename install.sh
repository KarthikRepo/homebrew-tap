#!/usr/bin/env bash
# Claude Monitor — fast installer
# Uses any available Python 3.10+ instead of requiring python@3.12 via Homebrew.
# Typical install time: ~60 seconds vs 5-7 minutes with brew install.
set -euo pipefail

INSTALL_DIR="$HOME/.claude_monitor"
VENV="$INSTALL_DIR/.venv"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/sources"

# ── Find Python 3.10+ ────────────────────────────────────────────────────────
find_python() {
  for py in python3.13 python3.12 python3.11 python3.10 python3; do
    local cmd
    cmd=$(command -v "$py" 2>/dev/null) || continue
    "$cmd" -c "import sys; assert sys.version_info >= (3,10), 'too old'" 2>/dev/null || continue
    echo "$cmd"; return 0
  done
  return 1
}

PYTHON=$(find_python) || {
  echo "Error: Python 3.10+ not found."
  echo "Install it with: brew install python@3.13"
  exit 1
}

echo "Claude Monitor installer"
echo "Python: $PYTHON ($($PYTHON --version))"
echo "Installing to: $INSTALL_DIR"
echo ""

# ── Copy source files ────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
cp "$SRC_DIR"/*.py "$INSTALL_DIR/"

# ── Create venv + install deps ───────────────────────────────────────────────
if [ ! -d "$VENV" ]; then
  "$PYTHON" -m venv "$VENV"
fi
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet --only-binary ':all:' 'pyobjc-framework-Cocoa==12.2'
"$VENV/bin/pip" install --quiet 'rumps==0.4.0'

# ── Create launcher ──────────────────────────────────────────────────────────
# Put launcher in /usr/local/bin or $(brew --prefix)/bin, whichever exists
if command -v brew &>/dev/null; then
  BIN_DIR="$(brew --prefix)/bin"
else
  BIN_DIR="/usr/local/bin"
  mkdir -p "$BIN_DIR"
fi
LAUNCHER="$BIN_DIR/claude-monitor"

cat > "$LAUNCHER" <<LAUNCH_EOF
#!/bin/bash
if pgrep -qf "claude_monitor/menubar.py" 2>/dev/null; then
  echo "Claude Monitor is already running — look for ◆ in your menu bar."
  exit 0
fi
nohup "$VENV/bin/python3" "$INSTALL_DIR/menubar.py" > /tmp/claude_monitor.log 2>&1 &
disown
echo "Claude Monitor started — look for ◆ in your menu bar."
LAUNCH_EOF
chmod +x "$LAUNCHER"

echo "Done! Installed to $INSTALL_DIR"
echo "Launcher: $LAUNCHER"
echo ""
echo "Run:  claude-monitor"
echo "Logs: /tmp/claude_monitor.log"
