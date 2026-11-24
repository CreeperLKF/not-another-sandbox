#!/bin/bash
# End-to-end test suite for not-another-sandbox (direct & sodo modes)
#
# Runs inside a disposable Linux / WSL environment (requires sudo/root + tmux).
# Creates a temporary agent account (default: nas-test-agent) and cleans up on exit.
#
# Usage:
#   ./tests/test-nas.sh [--human <user>] [--agent <temp-agent-user>] [--force]

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HUMAN_USER=""
AGENT_USER="nas-test-agent"
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --human) HUMAN_USER="${2:-}"; shift 2 ;;
    --agent) AGENT_USER="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--human <user>] [--agent <temp-agent-user>] [--force]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$HUMAN_USER" ]; then
  if [ "$(id -u)" -ne 0 ]; then
    HUMAN_USER="$(id -un)"
  elif [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    HUMAN_USER="$SUDO_USER"
  else
    echo "Error: running as root; please specify a non-root human account via --human <user>." >&2
    exit 1
  fi
fi

if [ "$HUMAN_USER" = "root" ] || ! id "$HUMAN_USER" >/dev/null 2>&1; then
  echo "Error: valid non-root --human account required (got '$HUMAN_USER')." >&2
  exit 1
fi

if [ "$FORCE" -eq 0 ] && { [ -e /etc/nas/sodo.conf ] || [ -e /usr/local/bin/nmux ] || [ -e /etc/sudoers.d/nas-sodo ]; }; then
  echo "Error: existing NAS sodo installation detected. Run ./uninstall.sh first or pass --force." >&2
  exit 1
fi

AGENT_PREEXISTED=0
if id "$AGENT_USER" >/dev/null 2>&1; then
  AGENT_PREEXISTED=1
fi

HUMAN_UID="$(id -u "$HUMAN_USER")"
AGENT_UID=""

run_as_human() {
  if [ "$(id -un)" = "$HUMAN_USER" ]; then
    env -u SUDO_USER -u SUDO_UID -u SUDO_GID -u SUDO_COMMAND bash -c "$1"
  else
    sudo -u "$HUMAN_USER" -H env -u SUDO_USER -u SUDO_UID -u SUDO_GID -u SUDO_COMMAND bash -c "$1"
  fi
}

run_as_agent() {
  sudo -u "$AGENT_USER" -H env -u SUDO_USER -u SUDO_UID -u SUDO_GID -u SUDO_COMMAND bash -c "$1"
}

cleanup() {
  set +e
  "$REPO_DIR/uninstall.sh" --yes --agent "$AGENT_USER" >/dev/null 2>&1 || true
  run_as_agent 'tmux kill-server' >/dev/null 2>&1 || true
  run_as_human 'tmux -L nmux-testwork kill-server; tmux -L default-priv kill-server' >/dev/null 2>&1 || true
  if [ "$AGENT_PREEXISTED" -eq 0 ] && id "$AGENT_USER" >/dev/null 2>&1; then
    AGENT_UID="$(id -u "$AGENT_USER" 2>/dev/null || true)"
    [ -n "$AGENT_UID" ] && sudo systemctl stop "user@${AGENT_UID}.service" >/dev/null 2>&1 || true
    sudo pkill -9 -u "$AGENT_USER" >/dev/null 2>&1 || true
    sleep 0.3
    sudo userdel -r "$AGENT_USER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

PASS=0
FAIL=0
check() {
  local desc="$1" ok="$2"
  if [ "$ok" = "1" ]; then
    echo "  [PASS] $desc"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] $desc"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== 1. Direct Mode Verification (human=$HUMAN_USER, agent=$AGENT_USER) ==="
(cd "$REPO_DIR" && ./install.sh --mode direct --agent "$AGENT_USER" --human "$HUMAN_USER" --skip-harden-wsl --skip-wsl-warning --yes) >/dev/null
AGENT_HOME="$(getent passwd "$AGENT_USER" | cut -d: -f6)"

[ ! -e /usr/local/bin/nmux ] && [ ! -e /etc/sudoers.d/nas-sodo ] && check "Direct mode installs zero binaries or sudoers" 1 || check "Direct mode installs zero binaries or sudoers" 0
[ "$(run_as_agent "cat '$AGENT_HOME/.config/nas/mode'")" = "direct" ] && check "Agent mode config set to direct" 1 || check "Agent mode config set to direct" 0

run_as_agent "tmux new-session -d -s directwork && tmux send-keys -t directwork 'id -un && echo DIRECT_E2E_OK' Enter"
sleep 0.4
DIRECT_CAP="$(run_as_agent "tmux capture-pane -t directwork -p")"
run_as_agent "tmux kill-session -t directwork"
printf '%s\n' "$DIRECT_CAP" | grep -q "DIRECT_E2E_OK" && check "Direct mode native tmux Act-Observe loop works" 1 || check "Direct mode native tmux Act-Observe loop works" 0

echo ""
echo "=== 2. Sodo Mode Installation & Trust Root ==="
(cd "$REPO_DIR" && ./install.sh --mode sodo --agent "$AGENT_USER" --human "$HUMAN_USER" --skip-harden-wsl --skip-wsl-warning --yes) >/dev/null

[ "$(stat -c '%a:%U:%G' /usr/local/bin/nmux)" = "755:root:root" ] && check "/usr/local/bin/nmux is 0755 root:root" 1 || check "/usr/local/bin/nmux is 0755 root:root" 0
[ "$(stat -c '%a:%U:%G' /etc/nas/sodo.conf)" = "644:root:root" ] && check "/etc/nas/sodo.conf is 0644 root:root" 1 || check "/etc/nas/sodo.conf is 0644 root:root" 0
sudo visudo -cf /etc/sudoers.d/nas-sodo >/dev/null 2>&1 && check "/etc/sudoers.d/nas-sodo passes visudo check" 1 || check "/etc/sudoers.d/nas-sodo passes visudo check" 0

echo ""
echo "=== 3. Sodo Mode Cross-UID Token Delegation & Security Boundaries ==="
CREATE_OUT="$(run_as_human "nmux create -d testwork")"
TOKEN="$(printf '%s\n' "$CREATE_OUT" | awk '/^Token:/ {print $2}')"
[ -n "$TOKEN" ] && check "nmux create returns ephemeral session token" 1 || check "nmux create returns ephemeral session token" 0
! compgen -G "/dev/shm/nmux-*" >/dev/null && check "Zero token files written to /dev/shm" 1 || check "Zero token files written to /dev/shm" 0

run_as_agent "test -w '/tmp/tmux-${HUMAN_UID}/nmux-testwork'" 2>/dev/null && check "Agent cannot write human tmux socket directly" 0 || check "Agent cannot write human tmux socket directly" 1

run_as_agent "printf '%s\n' '$TOKEN' | nmux testwork send-keys -t testwork 'id -un && echo SODO_PASS' Enter"
sleep 0.4
SODO_CAP="$(run_as_agent "printf '%s\n' '$TOKEN' | nmux testwork capture-pane -t testwork -p")"
if printf '%s\n' "$SODO_CAP" | grep -qx "$HUMAN_USER" && printf '%s\n' "$SODO_CAP" | grep -qx "SODO_PASS"; then
  check "Valid stdin token executes under human UID ($HUMAN_USER)" 1
else
  check "Valid stdin token executes under human UID ($HUMAN_USER)" 0
fi

# Security boundary rejections
run_as_agent "printf 'wrong-token\n' | nmux testwork list-panes" >/dev/null 2>&1 && check "Rejects wrong token" 0 || check "Rejects wrong token" 1
run_as_agent "printf '' | nmux testwork list-panes" >/dev/null 2>&1 && check "Rejects empty stdin" 0 || check "Rejects empty stdin" 1

run_as_human "tmux -L default-priv new-session -d -s priv"
run_as_agent "printf '%s\n' '$TOKEN' | nmux testwork -L default-priv list-sessions" >/dev/null 2>&1 && check "Blocks global -L flag escape" 0 || check "Blocks global -L flag escape" 1
run_as_agent "printf '%s\n' '$TOKEN' | nmux testwork -S /tmp/tmux-${HUMAN_UID}/default-priv list-sessions" >/dev/null 2>&1 && check "Blocks global -S flag escape" 0 || check "Blocks global -S flag escape" 1
run_as_agent "printf '%s\n' '$TOKEN' | nmux testwork -f /etc/passwd list-sessions" >/dev/null 2>&1 && check "Blocks global -f flag" 0 || check "Blocks global -f flag" 1
run_as_human "tmux -L default-priv kill-server" >/dev/null 2>&1 || true

run_as_agent "printf '%s\n' '$TOKEN' | nmux '../evil' list-panes" >/dev/null 2>&1 && check "Blocks '../' session path traversal" 0 || check "Blocks '../' session path traversal" 1
run_as_agent "sudo -n -u '$HUMAN_USER' /usr/local/bin/nmux create pwn" >/dev/null 2>&1 && check "Blocks agent sudo abuse of nmux create" 0 || check "Blocks agent sudo abuse of nmux create" 1
run_as_agent "sudo -n -u '$HUMAN_USER' /usr/local/bin/nmux kill testwork" >/dev/null 2>&1 && check "Blocks agent sudo abuse of nmux kill" 0 || check "Blocks agent sudo abuse of nmux kill" 1

# Revocation
run_as_human "nmux kill testwork" >/dev/null
run_as_agent "printf '%s\n' '$TOKEN' | nmux testwork list-panes" >/dev/null 2>&1 && check "Old token invalidated immediately on session kill" 0 || check "Old token invalidated immediately on session kill" 1

echo ""
echo "=== 4. Uninstall Verification ==="
run_as_human "nmux create -d leftover" >/dev/null
(cd "$REPO_DIR" && ./uninstall.sh --yes --agent "$AGENT_USER") >/dev/null

[ ! -e /etc/sudoers.d/nas-sodo ] && [ ! -e /usr/local/bin/nmux ] && [ ! -e /etc/nas ] && check "uninstall.sh removes sodo system files" 1 || check "uninstall.sh removes sodo system files" 0
[ ! -S "/tmp/tmux-${HUMAN_UID}/nmux-leftover" ] && check "uninstall.sh terminates active nmux-* sessions" 1 || check "uninstall.sh terminates active nmux-* sessions" 0
run_as_agent "test ! -e '$AGENT_HOME/.config/nas'" && check "uninstall.sh cleans agent ~/.config/nas" 1 || check "uninstall.sh cleans agent ~/.config/nas" 0

echo ""
echo "=========================================="
echo "NAS E2E SUMMARY: PASS=$PASS  FAIL=$FAIL"
echo "=========================================="
[ "$FAIL" -eq 0 ]
