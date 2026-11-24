#!/bin/bash
# not-another-sandbox (NAS) installer
# Default: direct mode (zero binaries, zero sudoers)
# Advanced: sodo mode (multi-agent token isolation via single-file /usr/local/bin/nmux)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

MODE=""
AGENT_USER=""
HUMAN_USER=""
AUTO_YES=0
HARDEN_WSL_CHOICE=""
WSL_WARNING_CHOICE=""

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --mode <direct|sodo>   Installation mode (default: direct)
  --agent <username>     Low-privilege agent account (default: nas-agent)
  --human <username>     Human account to elevate to (default: current user)
  --harden-wsl           Harden WSL interop sockets (0770) and /mnt/* mounts (umask=077)
  --skip-harden-wsl      Skip optional WSL system hardening without prompting
  --wsl-warning          Patch WSL interop warning into /nas-elevate skill if vulnerable
  --skip-wsl-warning     Skip WSL interop warning in /nas-elevate skill
  -y, --yes              Non-interactive mode (accept defaults)
  -h, --help             Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --agent) AGENT_USER="${2:-}"; shift 2 ;;
    --human) HUMAN_USER="${2:-}"; shift 2 ;;
    --harden-wsl) HARDEN_WSL_CHOICE="yes"; shift ;;
    --skip-harden-wsl) HARDEN_WSL_CHOICE="no"; shift ;;
    --wsl-warning) WSL_WARNING_CHOICE="yes"; shift ;;
    --skip-wsl-warning) WSL_WARNING_CHOICE="no"; shift ;;
    -y|--yes) AUTO_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

validate_username() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || {
    echo -e "${RED}Error: invalid username '$1'${NC}" >&2
    exit 1
  }
}

echo -e "${BOLD}not-another-sandbox Setup${NC}"
echo ""

# Check required dependency: tmux
if ! command -v tmux >/dev/null 2>&1; then
  echo -e "${RED}Error: tmux is required but not installed.${NC}" >&2
  echo "Install it first (e.g., sudo apt install -y tmux)." >&2
  exit 1
fi

# Step 1: Mode (default: direct)
if [ -z "$MODE" ]; then
  if [ "$AUTO_YES" -eq 1 ]; then
    MODE="direct"
  else
    echo -e "${BOLD}Step 1: Installation Mode${NC}"
    echo ""
    echo -e "1. ${YELLOW}direct${NC} (default) - Single agent / trusted agents"
    echo -e "   ${DIM}Zero binaries, zero sudoers, native tmux + /nas-elevate skill${NC}"
    echo ""
    echo -e "2. ${YELLOW}sodo${NC}   (advanced) - Multi-agent token isolation"
    echo -e "   ${DIM}Single-file shell /usr/local/bin/nmux + sudoers + in-memory tmux token${NC}"
    echo ""
    read -r -p "Select mode [1-2, default=1]: " MODE_NUM
    MODE_NUM="${MODE_NUM:-1}"
    case "$MODE_NUM" in
      1|direct) MODE="direct" ;;
      2|sodo) MODE="sodo" ;;
      *) echo "Invalid choice" >&2; exit 1 ;;
    esac
  fi
fi

case "$MODE" in
  direct|sodo) ;;
  *) echo "Error: mode must be 'direct' or 'sodo' (got '$MODE')" >&2; exit 1 ;;
esac

echo -e "${GREEN}Mode: $MODE${NC}"
echo ""

# Step 2: Accounts
CURRENT_USER="$(id -un)"
if [ -z "$AGENT_USER" ]; then
  if [ "$AUTO_YES" -eq 1 ]; then
    AGENT_USER="nas-agent"
  else
    read -r -p "Agent account name [default=nas-agent]: " AGENT_USER
    AGENT_USER="${AGENT_USER:-nas-agent}"
  fi
fi

if [ -z "$HUMAN_USER" ]; then
  if [ "$AUTO_YES" -eq 1 ]; then
    HUMAN_USER="$CURRENT_USER"
  else
    read -r -p "Human account (target for elevation) [default=$CURRENT_USER]: " HUMAN_USER
    HUMAN_USER="${HUMAN_USER:-$CURRENT_USER}"
  fi
fi

validate_username "$AGENT_USER"
validate_username "$HUMAN_USER"

if [ "$AGENT_USER" = "$HUMAN_USER" ]; then
  echo -e "${RED}Error: agent account and human account must be different users.${NC}" >&2
  exit 1
fi

if ! id "$HUMAN_USER" >/dev/null 2>&1; then
  echo -e "${RED}Error: human account '$HUMAN_USER' does not exist.${NC}" >&2
  exit 1
fi

# Create agent account if missing
if ! id "$AGENT_USER" >/dev/null 2>&1; then
  if [ "$AUTO_YES" -eq 1 ]; then
    CREATE_ACCOUNT="Y"
  else
    read -r -p "Agent account '$AGENT_USER' does not exist. Create it now? [Y/n]: " CREATE_ACCOUNT
    CREATE_ACCOUNT="${CREATE_ACCOUNT:-Y}"
  fi

  if [[ "$CREATE_ACCOUNT" =~ ^[Yy]$ ]]; then
    echo "Creating agent account '$AGENT_USER'..."
    sudo useradd -m -s /bin/bash "$AGENT_USER"
    echo -e "${GREEN}✓ Created agent account: $AGENT_USER${NC}"
  else
    echo "Cannot proceed without agent account." >&2
    exit 1
  fi
else
  echo -e "${GREEN}✓ Using existing agent account: $AGENT_USER${NC}"
fi

AGENT_HOME="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
[ -n "$AGENT_HOME" ] || { echo "Error: cannot resolve home directory for $AGENT_USER" >&2; exit 1; }

# Step 3: WSL Interop & DrvFS Exposure Check
wsl_interop_disabled() {
  sudo test -f /etc/wsl.conf 2>/dev/null || [ -f /etc/wsl.conf ] || return 1
  local content
  content="$(cat /etc/wsl.conf 2>/dev/null || sudo cat /etc/wsl.conf 2>/dev/null || true)"
  [ -n "$content" ] || return 1
  printf '%s\n' "$content" | awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[[:space:]]*\[/ {
      sec = tolower($0)
      gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", sec)
      in_interop = (sec == "interop")
      next
    }
    in_interop {
      line = tolower($0)
      gsub(/[[:space:]]/, "", line)
      if (line == "enabled=false") disabled = 1
      else if (line == "enabled=true") disabled = 0
    }
    END { exit(disabled ? 0 : 1) }
  '
}

IS_WSL=0
WSL_INTEROP_EXPOSED=0
WSL_DRVFS_EXPOSED=0
WSL_VULNERABLE=0

if grep -qi microsoft /proc/version 2>/dev/null || [ -d /run/WSL ]; then
  IS_WSL=1
  if ! wsl_interop_disabled && [ -d /run/WSL ]; then
    shopt -s nullglob
    for sock in /run/WSL/*_interop; do
      [ -L "$sock" ] && continue
      if [ -S "$sock" ] && sudo -u "$AGENT_USER" test -w "$sock" 2>/dev/null; then
        WSL_INTEROP_EXPOSED=1
        break
      fi
    done
    shopt -u nullglob
  fi

  if [ -r /proc/mounts ]; then
    while read -r _ mnt fstype opts _; do
      if [ "$fstype" = "9p" ] && [[ "$opts" == *"aname=drvfs"* ]]; then
        mnt="${mnt//\\040/ }"
        if sudo -u "$AGENT_USER" test -x "$mnt" 2>/dev/null || sudo -u "$AGENT_USER" test -r "$mnt" 2>/dev/null; then
          WSL_DRVFS_EXPOSED=1
          break
        fi
      fi
    done < /proc/mounts
  fi
fi

if [ "$IS_WSL" -eq 0 ] && [ "$HARDEN_WSL_CHOICE" = "yes" ]; then
  echo -e "${YELLOW}⚠ --harden-wsl ignored: WSL environment not detected.${NC}"
  HARDEN_WSL_CHOICE="no"
fi

if [ "$IS_WSL" -eq 1 ]; then
  if [ "$WSL_INTEROP_EXPOSED" -eq 1 ] || [ "$WSL_DRVFS_EXPOSED" -eq 1 ]; then
    echo ""
    echo -e "${YELLOW}⚠ WSL Isolation Warning:${NC}"
    if [ "$WSL_INTEROP_EXPOSED" -eq 1 ]; then
      echo "  - /run/WSL/*_interop sockets are writable by '$AGENT_USER' (allows root escape via wsl.exe -u root)."
    fi
    if [ "$WSL_DRVFS_EXPOSED" -eq 1 ]; then
      echo "  - Windows drives (/mnt/*) are accessible by '$AGENT_USER' via default drvfs permissions."
    fi

    if [ -z "$HARDEN_WSL_CHOICE" ]; then
      if [ "$AUTO_YES" -eq 1 ]; then
        HARDEN_WSL_CHOICE="no"
        echo "  Tip: re-run with --harden-wsl to lock down WSL interop sockets (0770) and /mnt/* mounts (umask=077)."
      else
        read -r -p "Apply optional WSL hardening (--harden-wsl: 0770 interop sockets + umask=077 on /mnt/*)? [y/N]: " ANS_HARDEN
        ANS_HARDEN="${ANS_HARDEN:-N}"
        if [[ "$ANS_HARDEN" =~ ^[Yy]$ ]]; then
          HARDEN_WSL_CHOICE="yes"
        else
          HARDEN_WSL_CHOICE="no"
        fi
      fi
    fi
  fi

  if [ "$HARDEN_WSL_CHOICE" != "yes" ] && [ "$WSL_INTEROP_EXPOSED" -eq 1 ]; then
    WSL_VULNERABLE=1
    if [ -z "$WSL_WARNING_CHOICE" ]; then
      if [ "$AUTO_YES" -eq 1 ]; then
        WSL_WARNING_CHOICE="yes"
      else
        read -r -p "Patch a soft WSL security notice into the /nas-elevate skill? [Y/n]: " ANS
        ANS="${ANS:-Y}"
        if [[ "$ANS" =~ ^[Yy]$ ]]; then
          WSL_WARNING_CHOICE="yes"
        else
          WSL_WARNING_CHOICE="no"
        fi
      fi
    fi
  fi
fi

# Step 4: Check existing installation state before making changes
HAS_SODO_ARTIFACTS=0
if [ -e /etc/sudoers.d/nas-sodo ] || [ -e /usr/local/bin/nmux ] || [ -e /etc/nas/sodo.conf ]; then
  HAS_SODO_ARTIFACTS=1
fi

if [ "$MODE" = "direct" ] && [ "$HAS_SODO_ARTIFACTS" -eq 1 ]; then
  echo "" >&2
  echo -e "${RED}Error: existing sodo installation detected (/usr/local/bin/nmux, /etc/nas/sodo.conf, or /etc/sudoers.d/nas-sodo).${NC}" >&2
  echo "Switching from sodo to direct requires removing the old sodo authorization first so mode and sudoers stay consistent." >&2
  echo "Please run:" >&2
  echo "  ./uninstall.sh" >&2
  echo "  ./install.sh --mode direct --agent $AGENT_USER --human $HUMAN_USER" >&2
  exit 1
fi

# Install mode-specific components
echo ""
if [ "$MODE" = "sodo" ] && [ "$HAS_SODO_ARTIFACTS" -eq 1 ]; then
  echo -e "${BOLD}Updating existing sodo installation in place...${NC}"
elif sudo -u "$AGENT_USER" test -f "$AGENT_HOME/.config/nas/mode"; then
  echo -e "${BOLD}Updating existing installation ($MODE mode)...${NC}"
else
  echo -e "${BOLD}Installing ($MODE mode)...${NC}"
fi

sudo -u "$AGENT_USER" mkdir -p "$AGENT_HOME/.config/nas"
printf '%s\n' "$MODE" | sudo -u "$AGENT_USER" tee "$AGENT_HOME/.config/nas/mode" >/dev/null
cat <<EOF | sudo -u "$AGENT_USER" tee "$AGENT_HOME/.config/nas/config" >/dev/null
mode=$MODE
human_user=$HUMAN_USER
agent_user=$AGENT_USER
EOF

if [ "$MODE" = "sodo" ]; then
  # Install single-file root-owned nmux
  sudo install -o root -g root -m 755 "$SCRIPT_DIR/scripts/nmux" /usr/local/bin/nmux

  # Atomically write root-owned config (trust root for nmux)
  sudo install -d -o root -g root -m 755 /etc/nas
  CONF_TMP="$(mktemp)"
  cat <<EOF > "$CONF_TMP"
HUMAN_USER=$HUMAN_USER
AGENT_USER=$AGENT_USER
EOF
  sudo install -o root -g root -m 644 "$CONF_TMP" /etc/nas/sodo.conf
  rm -f "$CONF_TMP"

  # Configure sudoers cleanly
  SUDOERS_TMP="$(mktemp)"
  cat <<EOF > "$SUDOERS_TMP"
Defaults!/usr/local/bin/nmux env_reset
$AGENT_USER ALL=($HUMAN_USER) NOPASSWD: /usr/local/bin/nmux
EOF
  if ! sudo visudo -cf "$SUDOERS_TMP" >/dev/null; then
    rm -f "$SUDOERS_TMP"
    echo -e "${RED}Error: generated sudoers syntax invalid; aborting.${NC}" >&2
    exit 1
  fi
  sudo install -o root -g root -m 440 "$SUDOERS_TMP" /etc/sudoers.d/nas-sodo
  rm -f "$SUDOERS_TMP"

  echo -e "${GREEN}✓ Installed /usr/local/bin/nmux, /etc/nas/sodo.conf, /etc/sudoers.d/nas-sodo${NC}"
else
  echo -e "${GREEN}✓ Direct mode configured (no extra binaries or sudoers)${NC}"
fi

# Step 4b: Optional WSL Hardening (--harden-wsl)
WSL_RESTART_NEEDED=0
if [ "$IS_WSL" -eq 1 ] && [ "$HARDEN_WSL_CHOICE" = "yes" ]; then
  echo ""
  echo -e "${BOLD}Applying WSL Hardening (--harden-wsl)...${NC}"

  HUMAN_UID="$(id -u "$HUMAN_USER")"
  HUMAN_GID="$(id -g "$HUMAN_USER")"
  HUMAN_GROUP="$(id -gn "$HUMAN_USER")"

  # 1. Runtime /run/WSL/*_interop socket hardening (0770 root:<group>) via systemd
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    OTHER_PRIMARY="$(getent passwd | awk -F: -v gid="$HUMAN_GID" -v hu="$HUMAN_USER" '$4 == gid && $1 != hu { print $1 }')"
    OTHER_SUPP="$(getent group "$HUMAN_GROUP" | cut -d: -f4 | tr ',' '\n' | awk -v hu="$HUMAN_USER" 'NF && $0 != hu { print $0 }')"
    if [ -z "$OTHER_PRIMARY" ] && [ -z "$OTHER_SUPP" ] && ! id -Gn "$AGENT_USER" | tr ' ' '\n' | grep -Fx "$HUMAN_GROUP" >/dev/null; then
      INTEROP_GROUP="$HUMAN_GROUP"
    else
      INTEROP_GROUP="nas-interop"
      sudo groupadd -f -r "$INTEROP_GROUP"
      sudo usermod -aG "$INTEROP_GROUP" "$HUMAN_USER"
      echo -e "${YELLOW}Note:${NC} Added '$HUMAN_USER' to group '$INTEROP_GROUP' (reopen WSL terminal to refresh group membership)."
    fi

    PATH_TMP="$(mktemp)"
    cat <<'EOF' > "$PATH_TMP"
# Managed by not-another-sandbox (--harden-wsl)
[Unit]
Description=NAS WSL Interop Socket Hardening (Watcher)
StartLimitIntervalSec=0

[Path]
PathChanged=/run/WSL

[Install]
WantedBy=multi-user.target
EOF

    SVC_TMP="$(mktemp)"
    cat <<EOF > "$SVC_TMP"
# Managed by not-another-sandbox (--harden-wsl)
[Unit]
Description=NAS WSL Interop Socket Hardening
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'if [ -d /run/WSL ]; then find /run/WSL -maxdepth 1 -name "*_interop" -type s \\( ! -group $INTEROP_GROUP -o ! -perm 0770 \\) -exec chgrp $INTEROP_GROUP {} + -exec chmod 0770 {} +; fi'

[Install]
WantedBy=multi-user.target
EOF

    sudo install -o root -g root -m 644 "$PATH_TMP" /etc/systemd/system/nas-wsl-interop.path
    sudo install -o root -g root -m 644 "$SVC_TMP" /etc/systemd/system/nas-wsl-interop.service
    rm -f "$PATH_TMP" "$SVC_TMP"

    sudo systemctl daemon-reload
    sudo systemctl reset-failed nas-wsl-interop.path nas-wsl-interop.service 2>/dev/null || true
    sudo systemctl enable --now nas-wsl-interop.path >/dev/null
    sudo systemctl enable nas-wsl-interop.service >/dev/null
    sudo systemctl start nas-wsl-interop.service
    echo -e "${GREEN}✓ Hardened /run/WSL/*_interop sockets (0770 root:$INTEROP_GROUP) via nas-wsl-interop.{path,service}${NC}"
  else
    echo -e "${YELLOW}⚠ systemd is not active in this WSL instance; skipped runtime /run/WSL/*_interop watcher.${NC}"
    if [ "$WSL_INTEROP_EXPOSED" -eq 1 ]; then
      WSL_VULNERABLE=1
      [ -z "$WSL_WARNING_CHOICE" ] && WSL_WARNING_CHOICE="yes"
    fi
  fi

  # 2. Persistent /mnt/* drvfs hardening via /etc/wsl.conf [automount]
  CLEAN_WSL="$(mktemp)"
  if sudo test -f /etc/wsl.conf; then
    sudo awk '
      /^# BEGIN NAS WSL HARDENING$/ { skip = 1; next }
      /^# END NAS WSL HARDENING$/ { skip = 0; next }
      !skip { print }
    ' /etc/wsl.conf > "$CLEAN_WSL"
  fi

  AUTOMOUNT_STATE="$(awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[[:space:]]*\[/ {
      sec = tolower($0)
      gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", sec)
      in_auto = (sec == "automount")
      if (in_auto) has_sec = 1
      next
    }
    in_auto && /^[[:space:]]*options[[:space:]]*=/ {
      has_opts = 1
      opts_line = $0
    }
    END {
      if (!has_sec) print "NO_SECTION"
      else if (!has_opts) print "NO_OPTIONS"
      else print "HAS_OPTIONS:" opts_line
    }
  ' "$CLEAN_WSL")"

  DESIRED_OPTS="options = \"uid=$HUMAN_UID,gid=$HUMAN_GID,umask=077\""
  NEW_WSL="$(mktemp)"

  case "$AUTOMOUNT_STATE" in
    NO_SECTION)
      awk '{ lines[NR] = $0 } END {
        last = NR
        while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
        for (i = 1; i <= last; i++) print lines[i]
        if (last > 0) print ""
      }' "$CLEAN_WSL" > "$NEW_WSL"
      cat <<EOF >> "$NEW_WSL"
# BEGIN NAS WSL HARDENING
[automount]
$DESIRED_OPTS
# END NAS WSL HARDENING
EOF
      sudo install -o root -g root -m 644 "$NEW_WSL" /etc/wsl.conf
      echo -e "${GREEN}✓ Configured /etc/wsl.conf [automount] ($DESIRED_OPTS)${NC}"
      [ "$WSL_DRVFS_EXPOSED" -eq 1 ] && WSL_RESTART_NEEDED=1
      ;;
    NO_OPTIONS)
      awk -v opts="$DESIRED_OPTS" '
        {
          print $0
          if (!inserted && $0 ~ /^[[:space:]]*\[[Aa][Uu][Tt][Oo][Mm][Oo][Uu][Nn][Tt]\][[:space:]]*$/) {
            print "# BEGIN NAS WSL HARDENING"
            print opts
            print "# END NAS WSL HARDENING"
            inserted = 1
          }
        }
      ' "$CLEAN_WSL" > "$NEW_WSL"
      sudo install -o root -g root -m 644 "$NEW_WSL" /etc/wsl.conf
      echo -e "${GREEN}✓ Added $DESIRED_OPTS under existing [automount] in /etc/wsl.conf${NC}"
      [ "$WSL_DRVFS_EXPOSED" -eq 1 ] && WSL_RESTART_NEEDED=1
      ;;
    HAS_OPTIONS:*)
      EXISTING_OPTS="${AUTOMOUNT_STATE#HAS_OPTIONS:}"
      if [[ "$EXISTING_OPTS" == *"umask=077"* ]] || [[ "$EXISTING_OPTS" == *"umask=0077"* ]]; then
        # Still write CLEAN_WSL if an old NAS block was stripped
        if [ -f /etc/wsl.conf ] && ! cmp -s "$CLEAN_WSL" /etc/wsl.conf; then
          sudo install -o root -g root -m 644 "$CLEAN_WSL" /etc/wsl.conf
        fi
        echo -e "${GREEN}✓ /etc/wsl.conf [automount] already restricts access ($EXISTING_OPTS)${NC}"
      else
        echo -e "${YELLOW}⚠ /etc/wsl.conf already defines custom [automount] options ($EXISTING_OPTS); left untouched.${NC}"
        echo "  To restrict /mnt/* from '$AGENT_USER', include uid=$HUMAN_UID,gid=$HUMAN_GID,umask=077 in [automount] options."
      fi
      ;;
  esac
  rm -f "$CLEAN_WSL" "$NEW_WSL"
fi

# Honor explicit --wsl-warning even if interop sockets were hardened
if [ "$IS_WSL" -eq 1 ] && [ "$WSL_WARNING_CHOICE" = "yes" ] && [ "$WSL_VULNERABLE" -eq 0 ] && [ "$HARDEN_WSL_CHOICE" != "yes" ]; then
  WSL_VULNERABLE=1
fi

# Step 5: Render and install /nas-elevate skill (MODE_MARKER + optional WSL_WARNING)
RENDERED_BLOCK="$(mktemp)"
if [ "$MODE" = "direct" ]; then
  cat <<EOF > "$RENDERED_BLOCK"
<!-- MODE_MARKER_START -->
**Current mode: \`direct\`** (human account: \`$HUMAN_USER\`, agent account: \`$AGENT_USER\`)

1. Ask the human to run in **agent account \`$AGENT_USER\`** (if currently in \`$HUMAN_USER\`, switch first via \`sudo -u $AGENT_USER -i\`):
   \`\`\`bash
   tmux new -s <session>
   su - $HUMAN_USER
   \`\`\`
   *(If root is needed, the human can also run \`sudo -v\` inside the pane.)*
2. Once confirmed, verify identity (\`id\`) and interact via tmux:
   \`\`\`bash
   tmux send-keys -t <session> 'id' Enter
   tmux capture-pane -t <session> -p | tail -80
   tmux send-keys -t <session> '<command>' Enter
   \`\`\`
3. Tell the human when done so they can destroy \`<session>\` (\`exit\` until the tmux session closes, or \`tmux kill-session -t <session>\`).
<!-- MODE_MARKER_END -->
EOF
else
  cat <<EOF > "$RENDERED_BLOCK"
<!-- MODE_MARKER_START -->
**Current mode: \`sodo\`** (human account: \`$HUMAN_USER\`, agent account: \`$AGENT_USER\`)

1. Ask the human to run in **human account \`$HUMAN_USER\`** (not in \`$AGENT_USER\`):
   \`\`\`bash
   nmux create <session>
   \`\`\`
   The human copies the printed token to you and presses Enter to attach and supervise *(and runs \`sudo -v\` inside the pane if root is needed)*.
2. Once confirmed, verify identity (\`id\`) and interact via \`nmux\`, passing the token on **stdin** on every call (never in argv):
   \`\`\`bash
   printf '%s\n' "\$TOKEN" | nmux <session> send-keys -t <session> 'id' Enter
   printf '%s\n' "\$TOKEN" | nmux <session> capture-pane -t <session> -p | tail -80
   printf '%s\n' "\$TOKEN" | nmux <session> send-keys -t <session> '<command>' Enter
   \`\`\`
3. Tell the human when done so they can destroy \`<session>\` (\`exit\` or \`nmux kill <session>\`), which immediately destroys the in-memory token.
<!-- MODE_MARKER_END -->
EOF
fi

WSL_BLOCK="$(mktemp)"
if [ "$WSL_VULNERABLE" -eq 1 ] && [ "$WSL_WARNING_CHOICE" = "yes" ]; then
  cat <<'EOF' > "$WSL_BLOCK"
<!-- WSL_WARNING_START -->
## WSL Security Notice

This WSL environment has `0777` interop sockets (`/run/WSL/*_interop`). Do NOT invoke `wsl.exe`, `cmd.exe`, or `powershell.exe` to bypass OS user isolation. Always use `/nas-elevate` instead.
<!-- WSL_WARNING_END -->
EOF
fi

RENDERED_SKILL="$(mktemp)"
awk -v modefile="$RENDERED_BLOCK" -v wslfile="$WSL_BLOCK" '
  /<!-- MODE_MARKER_START -->/ {
    while ((getline line < modefile) > 0) print line
    close(modefile)
    skip_mode = 1
    next
  }
  /<!-- MODE_MARKER_END -->/ {
    skip_mode = 0
    next
  }
  /<!-- WSL_WARNING_START -->/ {
    while ((getline line < wslfile) > 0) print line
    close(wslfile)
    skip_wsl = 1
    next
  }
  /<!-- WSL_WARNING_END -->/ {
    skip_wsl = 0
    next
  }
  !skip_mode && !skip_wsl { print }
' "$SCRIPT_DIR/skills/nas-elevate/SKILL.md" > "$RENDERED_SKILL"

# Install skill via `npx skills` (as AGENT_USER) when npx is available; fall back to direct copy
SKILL_INSTALLED_VIA_NPX=0
if sudo -u "$AGENT_USER" -H bash -lc 'command -v npx >/dev/null 2>&1'; then
  STAGE_DIR="$(sudo -u "$AGENT_USER" mktemp -d)"
  sudo -u "$AGENT_USER" mkdir -p "$STAGE_DIR/nas-elevate"
  sudo -u "$AGENT_USER" tee "$STAGE_DIR/nas-elevate/SKILL.md" < "$RENDERED_SKILL" >/dev/null

  NPX_ARGS=(-y skills add "$STAGE_DIR" -g -s nas-elevate)
  if [ "$AUTO_YES" -eq 1 ] || [ ! -t 0 ]; then
    NPX_ARGS+=(-a claude-code -y)
  fi

  echo "Installing /nas-elevate skill via npx skills (as $AGENT_USER)..."
  if sudo -u "$AGENT_USER" -H bash -lc 'exec npx "$@"' _ "${NPX_ARGS[@]}"; then
    SKILL_INSTALLED_VIA_NPX=1
    echo -e "${GREEN}✓ Installed /nas-elevate skill via npx skills${NC}"
  else
    echo -e "${YELLOW}⚠ npx skills failed (offline or unavailable); falling back to direct install.${NC}"
  fi
  sudo -u "$AGENT_USER" rm -rf -- "$STAGE_DIR"
else
  echo -e "${DIM}Note: npx not found in '$AGENT_USER' PATH; using direct skill install (~/.claude/skills/nas-elevate).${NC}"
fi

if [ "$SKILL_INSTALLED_VIA_NPX" -eq 0 ]; then
  SKILL_DIR="$AGENT_HOME/.claude/skills/nas-elevate"
  sudo -u "$AGENT_USER" mkdir -p "$SKILL_DIR"
  sudo -u "$AGENT_USER" tee "$SKILL_DIR/SKILL.md" < "$RENDERED_SKILL" >/dev/null
  echo -e "${GREEN}✓ Installed /nas-elevate skill at $SKILL_DIR/SKILL.md${NC}"
fi

if [ "$WSL_VULNERABLE" -eq 1 ] && [ "$WSL_WARNING_CHOICE" = "yes" ]; then
  echo -e "${GREEN}✓ Patched WSL security notice into /nas-elevate skill${NC}"
fi

rm -f "$RENDERED_BLOCK" "$WSL_BLOCK" "$RENDERED_SKILL"

echo ""
echo -e "${BOLD}${GREEN}✓ Installation Complete ($MODE mode)${NC}"
if [ "$WSL_RESTART_NEEDED" -eq 1 ]; then
  echo ""
  echo -e "${YELLOW}WSL Note:${NC} Restart this WSL distro once from Windows (e.g., wsl.exe --terminate \${WSL_DISTRO_NAME:-<Distro>})"
  echo "  so /mnt/* umask=077 takes effect. Keep shared agent project directories on the Linux filesystem (not /mnt/c)."
elif [ "$IS_WSL" -eq 1 ] && [ "$HARDEN_WSL_CHOICE" != "yes" ] && { [ "$WSL_INTEROP_EXPOSED" -eq 1 ] || [ "$WSL_DRVFS_EXPOSED" -eq 1 ]; }; then
  echo ""
  echo -e "${YELLOW}⚠ WSL Recommendation:${NC} WSL interop sockets or /mnt/* drives remain accessible to '$AGENT_USER'."
  echo "  Recommended: ./install.sh --mode $MODE --agent $AGENT_USER --human $HUMAN_USER --harden-wsl"
fi
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Start your agent:"
echo "       sudo -u $AGENT_USER -i"
if [ "$MODE" = "direct" ]; then
  echo "  2. First elevation test (direct mode):"
  echo "       Human (in $AGENT_USER): tmux new -s work  ->  su - $HUMAN_USER"
  echo "       Agent ($AGENT_USER):    tmux send-keys -t work 'whoami' Enter && tmux capture-pane -t work -p"
  echo "  3. Check / close orphan sessions anytime:"
  echo "       tmux ls   (in $AGENT_USER; exit or tmux kill-session -t <name> to revoke)"
else
  echo "  2. First elevation test (sodo mode):"
  echo "       Human ($HUMAN_USER): nmux create work"
  echo "       Agent ($AGENT_USER): printf '%s\\n' \"\$TOKEN\" | nmux work send-keys -t work 'whoami' Enter"
  echo "  3. Check / close orphan sessions anytime:"
  echo "       nmux ls   (in $HUMAN_USER; exit or nmux kill <name> to revoke)"
fi
if [ "$IS_WSL" -eq 1 ]; then
  if [ "$HARDEN_WSL_CHOICE" = "yes" ] && [ "$WSL_RESTART_NEEDED" -eq 1 ]; then
    echo "  4. WSL status: interop sockets hardened (0770); restart WSL once to apply /mnt/* umask=077"
  elif [ "$HARDEN_WSL_CHOICE" = "yes" ]; then
    echo "  4. WSL status: hardened (0770 interop sockets + /mnt/* umask=077)"
  elif [ "$WSL_INTEROP_EXPOSED" -eq 1 ] || [ "$WSL_DRVFS_EXPOSED" -eq 1 ]; then
    echo "  4. WSL status: unhardened (optional: re-run ./install.sh --harden-wsl)"
  else
    echo "  4. WSL status: isolated"
  fi
fi
if [ "$MODE" = "sodo" ] || [ "$HARDEN_WSL_CHOICE" = "yes" ]; then
  echo ""
  echo "To cleanly remove installed system rules/units and configs later: ./uninstall.sh"
fi
