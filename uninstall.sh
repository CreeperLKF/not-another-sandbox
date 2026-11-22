#!/bin/bash
# Uninstall script for not-another-sandbox

set -e

echo "=== not-another-sandbox Uninstall ==="
echo ""

# Detect mode
if [ -f ~/.config/nas/mode ]; then
  MODE=$(cat ~/.config/nas/mode)
  echo "Detected mode: $MODE"
else
  echo "No installation detected in ~/.config/nas/"
  read -p "Continue anyway? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 0
  fi
  MODE="unknown"
fi

echo ""
echo "This will remove:"
echo "  - Sudoers entries (/etc/sudoers.d/nas-*)"
echo "  - System binaries (/usr/local/bin/nmux*)"
echo "  - Configuration files (~/.config/nas/)"
echo "  - Agent skills (~/.claude/skills/nas-elevate)"
echo "  - Active tokens (/dev/shm/nmux-*)"
echo "  - Running tmux sessions (if any)"
echo ""
read -p "Proceed with uninstall? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Cancelled."
  exit 0
fi

echo ""
echo "--- Checking for active sessions ---"
SESSIONS=$(tmux list-sessions 2>/dev/null | grep -E '^(nas|work|elevated)' || true)
if [ -n "$SESSIONS" ]; then
  echo "Warning: Found potentially related tmux sessions:"
  echo "$SESSIONS"
  echo ""
  read -p "Kill these sessions? (y/N) " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    tmux list-sessions 2>/dev/null | grep -E '^(nas|work|elevated)' | cut -d: -f1 | xargs -I{} tmux kill-session -t {}
    echo "Sessions killed."
  else
    echo "Skipping session cleanup. You may need to close them manually."
  fi
fi

echo ""
echo "--- Removing sudoers entries ---"
if [ -d /etc/sudoers.d ]; then
  SUDOERS_FILES=$(sudo find /etc/sudoers.d -name 'nas-*' 2>/dev/null || true)
  if [ -n "$SUDOERS_FILES" ]; then
    echo "$SUDOERS_FILES" | while read -r file; do
      echo "  Removing: $file"
      sudo rm "$file"
    done
  else
    echo "  No sudoers entries found."
  fi
else
  echo "  /etc/sudoers.d not found (skipping)"
fi

echo ""
echo "--- Removing system binaries ---"
for bin in nmux nmux-verify nmuxd; do
  if [ -f /usr/local/bin/$bin ]; then
    echo "  Removing: /usr/local/bin/$bin"
    sudo rm /usr/local/bin/$bin
  fi
done

echo ""
echo "--- Removing configuration ---"
if [ -d ~/.config/nas ]; then
  echo "  Removing: ~/.config/nas/"
  rm -rf ~/.config/nas
fi

# Also check for agent user config if we can determine it
if [ -f ~/.config/nas/config ]; then
  AGENT_USER=$(grep agent_user ~/.config/nas/config | cut -d= -f2)
  if [ -n "$AGENT_USER" ] && id "$AGENT_USER" &>/dev/null; then
    echo "  Removing agent config: /home/$AGENT_USER/.config/nas/"
    sudo rm -rf /home/$AGENT_USER/.config/nas 2>/dev/null || true
  fi
fi

echo ""
echo "--- Removing skills ---"
SKILL_PATH=~/.claude/skills/nas-elevate
if [ -d "$SKILL_PATH" ]; then
  echo "  Removing: $SKILL_PATH"
  rm -rf "$SKILL_PATH"
fi

# Also check agent user
if [ -n "$AGENT_USER" ] && id "$AGENT_USER" &>/dev/null; then
  AGENT_SKILL_PATH=/home/$AGENT_USER/.claude/skills/nas-elevate
  if [ -d "$AGENT_SKILL_PATH" ]; then
    echo "  Removing: $AGENT_SKILL_PATH"
    sudo rm -rf "$AGENT_SKILL_PATH" 2>/dev/null || true
  fi
fi

echo ""
echo "--- Cleaning up tokens ---"
TOKEN_COUNT=$(ls /dev/shm/nmux-* 2>/dev/null | wc -l)
if [ "$TOKEN_COUNT" -gt 0 ]; then
  echo "  Found $TOKEN_COUNT token files in /dev/shm/"
  rm -f /dev/shm/nmux-* 2>/dev/null || sudo rm -f /dev/shm/nmux-*
  echo "  Tokens removed."
else
  echo "  No active tokens found."
fi

echo ""
echo "=== Uninstall complete ==="
echo ""
echo "The following were NOT removed (manual cleanup if needed):"
echo "  - Agent user account (if created during installation)"
echo "  - Built relay binaries in $(pwd)/bin/"
echo "  - Source code in $(pwd)/"
echo ""
echo "To remove the agent account (example):"
echo "  sudo userdel -r <agent-username>"
