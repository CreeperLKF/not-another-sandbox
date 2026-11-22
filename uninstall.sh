#!/bin/bash
# Uninstall script for not-another-sandbox (NAS)

set -euo pipefail

AUTO_YES=0
AGENT_USER=""
HUMAN_USER=""

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) AUTO_YES=1; shift ;;
    --agent) AGENT_USER="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Usage: ./uninstall.sh [-y|--yes] [--agent <username>]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Auto-detect accounts from /etc/nas/sodo.conf if present
if [ -f /etc/nas/sodo.conf ]; then
  while IFS='=' read -r key val; do
    case "$key" in
      AGENT_USER) [ -z "$AGENT_USER" ] && AGENT_USER="$val" ;;
      HUMAN_USER) [ -z "$HUMAN_USER" ] && HUMAN_USER="$val" ;;
    esac
  done < /etc/nas/sodo.conf
fi

# Fallback: try default agent account if still unknown
if [ -z "$AGENT_USER" ] && id nas-agent >/dev/null 2>&1; then
  AGENT_USER="nas-agent"
fi

echo "=== not-another-sandbox Uninstall ==="
echo ""
echo "This will remove:"
echo "  - Sudoers rule (/etc/sudoers.d/nas-sodo)"
echo "  - System script (/usr/local/bin/nmux)"
echo "  - System config (/etc/nas/)"
if [ -n "$AGENT_USER" ]; then
  echo "  - Agent config & /nas-elevate skill (as $AGENT_USER)"
fi
echo "  - Active nmux-* tmux sessions (if any)"
echo ""

if [ "$AUTO_YES" -eq 0 ]; then
  read -r -p "Proceed with uninstall? [y/N]: " REPLY
  [[ "$REPLY" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
fi

# 1. Kill active nmux-* tmux servers (both current user and configured human user)
cleanup_user_sockets() {
  local target_user="$1"
  local target_uid
  target_uid="$(id -u "$target_user" 2>/dev/null || true)"
  [ -n "$target_uid" ] || return 0
  local sock_dir="/tmp/tmux-$target_uid"
  [ -d "$sock_dir" ] || return 0
  shopt -s nullglob
  for sock in "$sock_dir"/nmux-*; do
    [ -S "$sock" ] || continue
    local base="${sock##*/}"
    echo "Stopping tmux server ($target_user): $base"
    if [ "$(id -un)" = "$target_user" ]; then
      tmux -L "$base" kill-server 2>/dev/null || true
      rm -f "$sock" 2>/dev/null || true
    else
      sudo -u "$target_user" tmux -L "$base" kill-server 2>/dev/null || true
      sudo -u "$target_user" rm -f -- "$sock" 2>/dev/null || true
    fi
  done
  shopt -u nullglob
}

cleanup_user_sockets "$(id -un)"
if [ -n "$HUMAN_USER" ] && [ "$HUMAN_USER" != "$(id -un)" ]; then
  cleanup_user_sockets "$HUMAN_USER"
fi

# 2. Remove root-owned system files installed by sodo mode
if [ -f /etc/sudoers.d/nas-sodo ]; then
  echo "Removing /etc/sudoers.d/nas-sodo"
  sudo rm -f /etc/sudoers.d/nas-sodo
fi

if [ -f /usr/local/bin/nmux ]; then
  echo "Removing /usr/local/bin/nmux"
  sudo rm -f /usr/local/bin/nmux
fi

if [ -d /etc/nas ]; then
  echo "Removing /etc/nas"
  sudo rm -rf /etc/nas
fi

# 3. Remove agent-side configs and skill (strictly as AGENT_USER, never as root)
if [ -n "$AGENT_USER" ] && id "$AGENT_USER" >/dev/null 2>&1; then
  if sudo -u "$AGENT_USER" -H bash -lc 'command -v npx >/dev/null 2>&1'; then
    echo "Removing /nas-elevate skill via npx skills (as $AGENT_USER)..."
    sudo -u "$AGENT_USER" -H bash -lc 'npx -y skills remove nas-elevate -g -y' >/dev/null 2>&1 || true
  fi

  AGENT_HOME="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
  if [ -n "$AGENT_HOME" ]; then
    for target in \
      "$AGENT_HOME/.config/nas" \
      "$AGENT_HOME/.claude/skills/nas-elevate" \
      "$AGENT_HOME/.agents/skills/nas-elevate"; do
      if sudo -u "$AGENT_USER" test -e "$target" || sudo -u "$AGENT_USER" test -L "$target"; then
        echo "Removing $target (as $AGENT_USER)"
        sudo -u "$AGENT_USER" rm -rf -- "$target"
      fi
    done
  fi
fi

echo ""
echo "=== Uninstall Complete ==="
if [ -n "$AGENT_USER" ]; then
  echo "Note: Agent user account '$AGENT_USER' was NOT deleted."
  echo "To delete it manually: sudo userdel -r $AGENT_USER"
fi
