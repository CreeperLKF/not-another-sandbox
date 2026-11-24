#!/bin/bash
# End-to-end test suite for not-another-sandbox WSL hardening (--harden-wsl)
#
# Scope: Verifies steady-state permission isolation (0770 interop sockets + 0700 /mnt/* mounts),
# systemd rapid-burst resilience, human/root interop retention, and clean uninstall rollback.
# Note: Does NOT test the transient millisecond-level TOCTOU race window on new host wsl.exe startup
# (documented under Section 5 of docs/design.md).
#
# Orchestrates testing from a WSL/Windows host against a disposable target WSL2 distro
# (restarts the target distro during testing and restores its original /etc/wsl.conf on exit).
#
# Usage:
#   ./tests/test-wsl-harden.sh --distro <wsl-distro-name> [--human <user>] [--agent <temp-agent>] [--wsl-exe <path>]

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISTRO=""
HUMAN_USER=""
AGENT_USER="nas-test-agent"
WSL_EXE="${WSL_EXE:-}"

usage() {
  cat <<'EOF'
Usage: ./tests/test-wsl-harden.sh --distro <wsl-distro-name> [options]

Options:
  --distro <name>    Target disposable WSL2 distribution to test against (required)
  --human <user>     Non-root human account inside target distro (default: auto-detect)
  --agent <user>     Temporary agent account created & deleted in target (default: nas-test-agent)
  --wsl-exe <path>   Path to Windows wsl.exe (default: auto-detect)
  -h, --help         Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --distro) DISTRO="${2:-}"; shift 2 ;;
    --human) HUMAN_USER="${2:-}"; shift 2 ;;
    --agent) AGENT_USER="${2:-}"; shift 2 ;;
    --wsl-exe) WSL_EXE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[ -n "$DISTRO" ] || { echo "Error: --distro <wsl-distro-name> is required." >&2; usage >&2; exit 1; }

if [ -z "$WSL_EXE" ]; then
  if command -v wsl.exe >/dev/null 2>&1; then
    WSL_EXE="$(command -v wsl.exe)"
  elif [ -x /mnt/c/Windows/System32/wsl.exe ]; then
    WSL_EXE="/mnt/c/Windows/System32/wsl.exe"
  else
    echo "Error: cannot locate wsl.exe; pass --wsl-exe <path>." >&2
    exit 1
  fi
fi

# Guard against accidentally targeting the current active WSL distro
if [ -n "${WSL_DISTRO_NAME:-}" ] && [ "$WSL_DISTRO_NAME" = "$DISTRO" ]; then
  echo "Error: --distro '$DISTRO' matches the currently running WSL_DISTRO_NAME; run from another distro or host shell because the target distro will be restarted." >&2
  exit 1
fi

wsl_root() {
  "$WSL_EXE" -d "$DISTRO" -u root -- bash -s
}

wsl_human() {
  "$WSL_EXE" -d "$DISTRO" -u "$HUMAN_USER" -- bash -s
}

# Detect default non-root human user in target distro if not specified
if [ -z "$HUMAN_USER" ]; then
  HUMAN_USER="$("$WSL_EXE" -d "$DISTRO" -- id -un < /dev/null | tr -d '\r\n')"
  if [ -z "$HUMAN_USER" ] || [ "$HUMAN_USER" = "root" ]; then
    echo "Error: target distro default user is root; pass --human <non-root-user>." >&2
    exit 1
  fi
fi

STAGE_DIR="/opt/nas-wsl-e2e-$$"
SUDOERS_TEMP="/etc/sudoers.d/zz-nas-wsl-e2e-$$"
BG_PID=""

cleanup() {
  set +e
  [ -n "$BG_PID" ] && kill "$BG_PID" >/dev/null 2>&1 || true
  wsl_root <<EOF >/dev/null 2>&1 || true
if [ -x "$STAGE_DIR/uninstall.sh" ]; then
  "$STAGE_DIR/uninstall.sh" --yes --agent "$AGENT_USER" >/dev/null 2>&1 || true
fi
if [ "\${AGENT_PREEXISTED:-0}" = "0" ] && id "$AGENT_USER" >/dev/null 2>&1; then
  auid="\$(id -u "$AGENT_USER" 2>/dev/null || true)"
  [ -n "\$auid" ] && systemctl stop "user@\${auid}.service" 2>/dev/null || true
  pkill -9 -u "$AGENT_USER" 2>/dev/null || true
  sleep 0.3
  userdel -r "$AGENT_USER" 2>/dev/null || true
fi
rm -f "$SUDOERS_TEMP" /root/.nas-wsl-conf-baseline.$$
rm -rf "$STAGE_DIR"
if [ -f /root/.nas-wsl-conf-had-orig.$$ ]; then
  mv -f /root/.nas-wsl-conf-orig.$$ /etc/wsl.conf
  rm -f /root/.nas-wsl-conf-had-orig.$$
elif [ -f /root/.nas-wsl-conf-no-orig.$$ ]; then
  rm -f /etc/wsl.conf /root/.nas-wsl-conf-no-orig.$$
fi
EOF
  "$WSL_EXE" --terminate "$DISTRO" < /dev/null >/dev/null 2>&1 || true
}
trap cleanup EXIT

AGENT_PREEXISTED="$(wsl_root <<EOF
id "$AGENT_USER" >/dev/null 2>&1 && echo 1 || echo 0
EOF
)"
AGENT_PREEXISTED="${AGENT_PREEXISTED//$'\r'/}"

echo "=== Preparing disposable WSL2 test environment on '$DISTRO' (human=$HUMAN_USER, agent=$AGENT_USER) ==="
wsl_root <<EOF
if [ -f /etc/wsl.conf ]; then
  cp -a /etc/wsl.conf /root/.nas-wsl-conf-orig.$$
  touch /root/.nas-wsl-conf-had-orig.$$
else
  touch /root/.nas-wsl-conf-no-orig.$$
fi
cat <<CONF > /etc/wsl.conf
[boot]
systemd=true

[user]
default=$HUMAN_USER
CONF
cp -a /etc/wsl.conf /root/.nas-wsl-conf-baseline.$$
echo "$HUMAN_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_TEMP"
chmod 440 "$SUDOERS_TEMP"
EOF

"$WSL_EXE" --terminate "$DISTRO" < /dev/null
sleep 2

tar -C "$REPO_DIR" --exclude='.git' -cf - . | "$WSL_EXE" -d "$DISTRO" -u root -- bash -c "rm -rf '$STAGE_DIR' && mkdir -p '$STAGE_DIR' && tar -C '$STAGE_DIR' -xf - && chown -R '$HUMAN_USER:$HUMAN_USER' '$STAGE_DIR'"

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

"$WSL_EXE" -d "$DISTRO" -u "$HUMAN_USER" -- sleep 20 < /dev/null &
BG_PID=$!
sleep 2

echo "=== 1. Default direct install (--yes, without --harden-wsl) ==="
OUT1="$(wsl_human <<EOF 2>&1
cd "$STAGE_DIR"
./install.sh --mode direct --agent "$AGENT_USER" --human "$HUMAN_USER" --yes
EOF
)"
echo "$OUT1" | grep -q "WSL Isolation Warning" && check "Detects WSL interop & drvfs exposure" 1 || check "Detects WSL interop & drvfs exposure" 0
(echo "$OUT1" | grep -q "WSL Recommendation:" && echo "$OUT1" | grep -q "Recommended:.*--harden-wsl") && check "Non-interactive -y prints end-of-install --harden-wsl recommendation" 1 || check "Non-interactive -y prints end-of-install --harden-wsl recommendation" 0

T1="$(wsl_root <<EOF
[ ! -e /etc/systemd/system/nas-wsl-interop.path ] && echo NO_UNIT=1 || echo NO_UNIT=0
cmp -s /etc/wsl.conf /root/.nas-wsl-conf-baseline.$$ && echo WSL_CONF_UNTOUCHED=1 || echo WSL_CONF_UNTOUCHED=0
AGENT_HOME="\$(getent passwd "$AGENT_USER" | cut -d: -f6)"
if grep -rq "WSL Security Notice" "\$AGENT_HOME/.claude/skills/nas-elevate" "\$AGENT_HOME/.agents" 2>/dev/null; then
  echo SOFT_NOTICE=1
else
  echo SOFT_NOTICE=0
fi
EOF
)"
echo "$T1" | grep -q "NO_UNIT=1" && check "Default --yes installs zero systemd units" 1 || check "Default --yes installs zero systemd units" 0
echo "$T1" | grep -q "WSL_CONF_UNTOUCHED=1" && check "Default --yes leaves /etc/wsl.conf untouched" 1 || check "Default --yes leaves /etc/wsl.conf untouched" 0
echo "$T1" | grep -q "SOFT_NOTICE=1" && check "Default --yes patches soft WSL notice into skill" 1 || check "Default --yes patches soft WSL notice into skill" 0

echo ""
echo "=== 2. Install with --harden-wsl (immediate socket lockdown + /etc/wsl.conf update) ==="
OUT2="$(wsl_human <<EOF 2>&1
cd "$STAGE_DIR"
./install.sh --mode direct --agent "$AGENT_USER" --human "$HUMAN_USER" --harden-wsl --yes
EOF
)"
echo "$OUT2" | grep -q "Hardened /run/WSL/\*_interop sockets (0770" && check "--harden-wsl hardens sockets to 0770" 1 || check "--harden-wsl hardens sockets to 0770" 0
echo "$OUT2" | grep -q "WSL Note:.*Restart this WSL distro once" && check "--harden-wsl prints one-time WSL restart note" 1 || check "--harden-wsl prints one-time WSL restart note" 0

T2="$(wsl_root <<EOF
sleep 0.2
su - "$HUMAN_USER" -c '/mnt/c/Windows/System32/cmd.exe /c echo HUMAN_IMM_OK < /dev/null 2>&1 | tr -d "\r"'
su - "$AGENT_USER" -c '
  blocked=1
  for s in /run/WSL/*_interop; do
    [ -L "\$s" ] && continue
    [ -S "\$s" ] || continue
    if [ -w "\$s" ]; then blocked=0; fi
  done
  echo "IMM_BLOCKED=\$blocked"
'
EOF
)"
echo "$T2" | grep -q "HUMAN_IMM_OK" && check "Human cmd.exe works immediately without re-login" 1 || check "Human cmd.exe works immediately without re-login" 0
echo "$T2" | grep -q "IMM_BLOCKED=1" && check "Agent loses write access to all /run/WSL/*_interop sockets" 1 || check "Agent loses write access to all /run/WSL/*_interop sockets" 0

wait "$BG_PID" 2>/dev/null || true
BG_PID=""

echo ""
echo "=== 3. Restart target distro & test cold boot, rapid 8x session burst, /mnt/* umask=077, raw AF_UNIX block ==="
"$WSL_EXE" --terminate "$DISTRO" < /dev/null
sleep 2

# Re-stage repo if /opt persisted (it does on ext4 rootfs) and keep distro running
"$WSL_EXE" -d "$DISTRO" -u "$HUMAN_USER" -- sleep 25 < /dev/null &
BG_PID=$!
sleep 3

for _ in 1 2 3 4 5 6 7 8; do
  "$WSL_EXE" -d "$DISTRO" -u "$HUMAN_USER" -- true < /dev/null
done

T3="$(wsl_root <<EOF
sleep 0.3
HUMAN_GROUP="\$(id -gn "$HUMAN_USER")"
systemctl is-active nas-wsl-interop.path | grep -qx active && echo PATH_ACTIVE=1 || echo PATH_ACTIVE=0
[ "\$(stat -c '%a:%U:%G' /mnt/c)" = "700:$HUMAN_USER:\$HUMAN_GROUP" ] && echo MNTC_700=1 || echo MNTC_700=0
su - "$HUMAN_USER" -c 'ls /mnt/c >/dev/null 2>&1 && echo HUMAN_MNTC_OK=1 || echo HUMAN_MNTC_OK=0'
su - "$HUMAN_USER" -c '/mnt/c/Windows/System32/cmd.exe /c echo HUMAN_POSTBOOT_OK < /dev/null 2>&1 | tr -d "\r" | grep -q HUMAN_POSTBOOT_OK && echo HUMAN_CMD_OK=1 || echo HUMAN_CMD_OK=0'
ls /mnt/c >/dev/null 2>&1 && echo ROOT_MNTC_OK=1 || echo ROOT_MNTC_OK=0
/mnt/c/Windows/System32/cmd.exe /c echo ROOT_POSTBOOT_OK < /dev/null 2>&1 | tr -d "\r" | grep -q ROOT_POSTBOOT_OK && echo ROOT_CMD_OK=1 || echo ROOT_CMD_OK=0
su - "$AGENT_USER" -c '
  ls /mnt/c >/dev/null 2>&1 && echo AGENT_MNTC_BLOCKED=0 || echo AGENT_MNTC_BLOCKED=1
  /mnt/c/Windows/System32/wsl.exe --status < /dev/null >/dev/null 2>&1 && echo AGENT_EXE_BLOCKED=0 || echo AGENT_EXE_BLOCKED=1
  python3 - << "PY"
import glob, os, socket
socks = [s for s in glob.glob("/run/WSL/*_interop") if not os.path.islink(s)]
all_eacces = len(socks) > 0
for p in socks:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(p)
        all_eacces = False
    except PermissionError:
        pass
    finally:
        s.close()
print("AGENT_RAW_SOCK_BLOCKED=" + ("1" if all_eacces else "0"))
PY
'
EOF
)"
echo "$T3" | grep -q "PATH_ACTIVE=1" && check "nas-wsl-interop.path stays active after 8x rapid session burst" 1 || check "nas-wsl-interop.path stays active after 8x rapid session burst" 0
echo "$T3" | grep -q "MNTC_700=1" && check "/mnt/c mounted as 0700 owned by human after restart" 1 || check "/mnt/c mounted as 0700 owned by human after restart" 0
echo "$T3" | grep -q "HUMAN_MNTC_OK=1" && check "Human retains /mnt/c access" 1 || check "Human retains /mnt/c access" 0
echo "$T3" | grep -q "HUMAN_CMD_OK=1" && check "Human retains Windows cmd.exe interop" 1 || check "Human retains Windows cmd.exe interop" 0
echo "$T3" | grep -q "ROOT_MNTC_OK=1" && check "Root retains /mnt/c access" 1 || check "Root retains /mnt/c access" 0
echo "$T3" | grep -q "ROOT_CMD_OK=1" && check "Root retains Windows cmd.exe interop" 1 || check "Root retains Windows cmd.exe interop" 0
echo "$T3" | grep -q "AGENT_MNTC_BLOCKED=1" && check "Agent blocked from /mnt/c (Permission denied)" 1 || check "Agent blocked from /mnt/c (Permission denied)" 0
echo "$T3" | grep -q "AGENT_EXE_BLOCKED=1" && check "Agent blocked from executing /mnt/c/.../wsl.exe" 1 || check "Agent blocked from executing /mnt/c/.../wsl.exe" 0
echo "$T3" | grep -q "AGENT_RAW_SOCK_BLOCKED=1" && check "Agent raw AF_UNIX connect() blocked with EACCES on all *_interop sockets" 1 || check "Agent raw AF_UNIX connect() blocked with EACCES on all *_interop sockets" 0

echo ""
echo "=== 4. Idempotent upgrade to sodo + --harden-wsl & nmux delegation flow ==="
OUT4="$(wsl_human <<EOF 2>&1
cd "$STAGE_DIR"
./install.sh --mode sodo --agent "$AGENT_USER" --human "$HUMAN_USER" --harden-wsl --yes
EOF
)"
echo "$OUT4" | grep -q "WSL Note:" && check "No redundant restart nag when /mnt/c already 0700" 0 || check "No redundant restart nag when /mnt/c already 0700" 1

T4="$(wsl_root <<EOF
CNT=\$(grep -c '^# BEGIN NAS WSL HARDENING$' /etc/wsl.conf)
echo "BLOCK_CNT=\$CNT"
CREATE_OUT=\$(su - "$HUMAN_USER" -c 'nmux create -d e2ework')
TOK=\$(printf '%s\n' "\$CREATE_OUT" | awk '/^Token:/ {print \$2}')
su - "$AGENT_USER" -c "printf '%s\n' '\$TOK' | nmux e2ework send-keys -t e2ework 'id -un && echo SODO_WSL_OK' Enter"
sleep 0.5
CAP=\$(su - "$AGENT_USER" -c "printf '%s\n' '\$TOK' | nmux e2ework capture-pane -t e2ework -p")
su - "$HUMAN_USER" -c 'nmux kill e2ework' >/dev/null
if printf '%s\n' "\$CAP" | grep -qx "$HUMAN_USER" && printf '%s\n' "\$CAP" | grep -qx 'SODO_WSL_OK'; then
  echo SODO_FLOW_OK=1
else
  echo SODO_FLOW_OK=0
fi
EOF
)"
echo "$T4" | grep -q "BLOCK_CNT=1" && check "Idempotent /etc/wsl.conf has exactly 1 NAS block" 1 || check "Idempotent /etc/wsl.conf has exactly 1 NAS block" 0
echo "$T4" | grep -q "SODO_FLOW_OK=1" && check "Sodo nmux delegation works seamlessly alongside --harden-wsl" 1 || check "Sodo nmux delegation works seamlessly alongside --harden-wsl" 0

echo ""
echo "=== 5. Custom [automount] options preservation check ==="
wsl_root <<'EOF'
cp -a /etc/wsl.conf /root/.nas-wsl-before-t5
cat <<CONF > /etc/wsl.conf
[boot]
systemd=true

[automount]
options = "metadata"
CONF
EOF

OUT5="$(wsl_human <<EOF 2>&1
cd "$STAGE_DIR"
./install.sh --mode sodo --agent "$AGENT_USER" --human "$HUMAN_USER" --harden-wsl --yes
EOF
)"
echo "$OUT5" | grep -q "already defines custom \[automount\] options" && check "Warns without overwriting custom user [automount] options" 1 || check "Warns without overwriting custom user [automount] options" 0

T5="$(wsl_root <<'EOF'
grep -q '^options = "metadata"$' /etc/wsl.conf && echo CUSTOM_KEPT=1 || echo CUSTOM_KEPT=0
mv -f /root/.nas-wsl-before-t5 /etc/wsl.conf
EOF
)"
echo "$T5" | grep -q "CUSTOM_KEPT=1" && check "Custom [automount] options preserved intact" 1 || check "Custom [automount] options preserved intact" 0

echo ""
echo "=== 6. Full uninstall.sh verification ==="
wsl_human <<EOF >/dev/null
cd "$STAGE_DIR"
./uninstall.sh --yes --agent "$AGENT_USER"
EOF

T6="$(wsl_root <<EOF
[ ! -e /etc/systemd/system/nas-wsl-interop.path ] && [ ! -e /etc/systemd/system/nas-wsl-interop.service ] && echo UNITS_GONE=1 || echo UNITS_GONE=0
cmp -s /etc/wsl.conf /root/.nas-wsl-conf-baseline.$$ && echo WSL_RESTORED_EXACT=1 || echo WSL_RESTORED_EXACT=0
[ ! -e /etc/sudoers.d/nas-sodo ] && [ ! -e /usr/local/bin/nmux ] && echo SODO_GONE=1 || echo SODO_GONE=0
restored_777=1
for s in /run/WSL/*_interop; do
  [ -L "\$s" ] && continue
  [ -S "\$s" ] || continue
  [ "\$(stat -c '%a:%U:%G' "\$s")" = "777:root:root" ] || restored_777=0
done
echo "SOCKS_777=\$restored_777"
EOF
)"
echo "$T6" | grep -q "UNITS_GONE=1" && check "uninstall.sh removes nas-wsl-interop.{path,service}" 1 || check "uninstall.sh removes nas-wsl-interop.{path,service}" 0
echo "$T6" | grep -q "WSL_RESTORED_EXACT=1" && check "uninstall.sh restores /etc/wsl.conf byte-for-byte" 1 || check "uninstall.sh restores /etc/wsl.conf byte-for-byte" 0
echo "$T6" | grep -q "SODO_GONE=1" && check "uninstall.sh removes sodo files" 1 || check "uninstall.sh removes sodo files" 0
echo "$T6" | grep -q "SOCKS_777=1" && check "uninstall.sh restores active *_interop sockets to 0777 root:root" 1 || check "uninstall.sh restores active *_interop sockets to 0777 root:root" 0

echo ""
echo "=========================================="
echo "WSL HARDEN E2E SUMMARY: PASS=$PASS  FAIL=$FAIL"
echo "=========================================="
[ "$FAIL" -eq 0 ]
