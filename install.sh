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
WSL_WARNING_CHOICE=""

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --mode <direct|sodo>   Installation mode (default: direct)
  --agent <username>     Low-privilege agent account (default: nas-agent)
  --human <username>     Human account to elevate to (default: current user)
  --wsl-warning          Add WSL interop warning prompt if vulnerable
  --skip-wsl-warning     Skip WSL interop warning prompt
  -y, --yes              Non-interactive mode (accept defaults)
  -h, --help             Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --agent) AGENT_USER="${2:-}"; shift 2 ;;
    --human) HUMAN_USER="${2:-}"; shift 2 ;;
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

# Step 3: WSL Interop Check
WSL_VULNERABLE=0
if grep -qi microsoft /proc/version 2>/dev/null || [ -d /run/WSL ]; then
  shopt -s nullglob
  for sock in /run/WSL/*_interop; do
    if [ -S "$sock" ]; then
      PERMS="$(stat -c %a "$sock" 2>/dev/null || echo "")"
      if [ "$PERMS" = "777" ]; then
        WSL_VULNERABLE=1
        break
      fi
    fi
  done
  shopt -u nullglob

  if [ "$WSL_VULNERABLE" -eq 1 ]; then
    echo ""
    echo -e "${YELLOW}⚠ WSL Interop Warning:${NC} /run/WSL/*_interop sockets are 0777."
    echo "  Any local user can bypass OS isolation via wsl.exe -u root."
    if [ -z "$WSL_WARNING_CHOICE" ]; then
      if [ "$AUTO_YES" -eq 1 ]; then
        WSL_WARNING_CHOICE="yes"
      else
        read -r -p "Add a soft warning notice to agent's ~/.claude/prompts/wsl-warning.txt? [Y/n]: " ANS
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

# Step 4: Install mode-specific components
echo ""
echo -e "${BOLD}Installing ($MODE mode)...${NC}"

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

  # Write root-owned config (trust root for nmux)
  sudo install -d -o root -g root -m 755 /etc/nas
  cat <<EOF | sudo tee /etc/nas/sodo.conf >/dev/null
HUMAN_USER=$HUMAN_USER
AGENT_USER=$AGENT_USER
EOF
  sudo chown root:root /etc/nas/sodo.conf
  sudo chmod 644 /etc/nas/sodo.conf

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

# Step 5: Install /nas-elevate skill with rendered MODE_MARKER
SKILL_DIR="$AGENT_HOME/.claude/skills/nas-elevate"
sudo -u "$AGENT_USER" mkdir -p "$SKILL_DIR"

RENDERED_BLOCK="$(mktemp)"
if [ "$MODE" = "direct" ]; then
  cat <<EOF > "$RENDERED_BLOCK"
<!-- MODE_MARKER_START -->
**Current mode: \`direct\`** (human account: \`$HUMAN_USER\`)

1. Ask the human to run (in agent account \`$AGENT_USER\`):
   \`\`\`bash
   tmux new -s work
   su - $HUMAN_USER
   \`\`\`
2. Once confirmed, interact directly via tmux:
   \`\`\`bash
   tmux send-keys -t work "apt update" Enter
   tmux capture-pane -t work -p
   \`\`\`
3. Tell the human when done so they can close tmux (\`exit\` / \`tmux kill-session -t work\`).
<!-- MODE_MARKER_END -->
EOF
else
  cat <<EOF > "$RENDERED_BLOCK"
<!-- MODE_MARKER_START -->
**Current mode: \`sodo\`** (human account: \`$HUMAN_USER\`)

1. Ask the human to run (in human account \`$HUMAN_USER\`):
   \`\`\`bash
   nmux create work
   \`\`\`
   The human copies the printed token to you and presses Enter to attach and supervise.
2. Interact via \`nmux\`, passing the token on **stdin** on every call (never in argv):
   \`\`\`bash
   printf '%s\n' "\$TOKEN" | nmux work send-keys -t work "apt update" Enter
   printf '%s\n' "\$TOKEN" | nmux work capture-pane -t work -p
   \`\`\`
3. Tell the human when done so they can close tmux (\`exit\` or \`nmux kill work\`), which immediately destroys the in-memory token.
<!-- MODE_MARKER_END -->
EOF
fi

RENDERED_SKILL="$(mktemp)"
awk -v blockfile="$RENDERED_BLOCK" '
  /<!-- MODE_MARKER_START -->/ {
    while ((getline line < blockfile) > 0) print line
    close(blockfile)
    skip = 1
    next
  }
  /<!-- MODE_MARKER_END -->/ {
    skip = 0
    next
  }
  !skip { print }
' "$SCRIPT_DIR/skills/nas-elevate/SKILL.md" > "$RENDERED_SKILL"

sudo -u "$AGENT_USER" tee "$SKILL_DIR/SKILL.md" < "$RENDERED_SKILL" >/dev/null
rm -f "$RENDERED_BLOCK" "$RENDERED_SKILL"
echo -e "${GREEN}✓ Installed /nas-elevate skill at $SKILL_DIR/SKILL.md${NC}"

# Optional WSL prompt warning
if [ "$WSL_VULNERABLE" -eq 1 ] && [ "$WSL_WARNING_CHOICE" = "yes" ]; then
  WARN_FILE="$AGENT_HOME/.claude/prompts/wsl-warning.txt"
  sudo -u "$AGENT_USER" mkdir -p "$(dirname "$WARN_FILE")"
  cat <<'EOF' | sudo -u "$AGENT_USER" tee "$WARN_FILE" >/dev/null
WSL Security Notice:
This WSL environment has 0777 interop sockets. Do NOT invoke wsl.exe, cmd.exe,
or powershell.exe for privilege escalation. Always use /nas-elevate instead.
EOF
  echo -e "${GREEN}✓ Added WSL warning at $WARN_FILE${NC}"
fi

echo ""
echo -e "${BOLD}${GREEN}✓ Installation Complete ($MODE mode)${NC}"
echo ""
if [ "$MODE" = "direct" ]; then
  echo "Quick test:"
  echo "  Human (in $AGENT_USER): tmux new -s work  ->  su - $HUMAN_USER"
  echo "  Agent ($AGENT_USER):    tmux send-keys -t work 'whoami' Enter && tmux capture-pane -t work -p"
else
  echo "Quick test:"
  echo "  Human ($HUMAN_USER): nmux create work"
  echo "  Agent ($AGENT_USER): printf '%s\\n' \"\$TOKEN\" | nmux work send-keys -t work 'whoami' Enter"
  echo ""
  echo "To remove sudoers, /usr/local/bin/nmux, and configs later: ./uninstall.sh"
fi
