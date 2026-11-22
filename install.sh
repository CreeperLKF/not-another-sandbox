#!/bin/bash
set -e

# not-another-sandbox installer
# Interactive setup for privilege delegation system

BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BOLD}not-another-sandbox Setup${NC}"
echo ""
echo "Welcome! This will set up privilege delegation for AI agents"
echo "under human supervision."
echo ""

# Step 1: Choose mode
echo -e "${BOLD}Step 1: Installation Mode${NC}"
echo ""
echo "1. ${YELLOW}direct${NC}  - Single agent, no tokens (recommended)"
echo "   ${DIM}✓ Simplest, zero overhead, no extra binaries${NC}"
echo "   ${DIM}✗ Any agent with same UID can attach${NC}"
echo ""
echo "2. relay   - Multi-agent, daemon-based"
echo "   ${DIM}✓ Strong isolation, token auth${NC}"
echo "   ${DIM}✗ Requires Go or download binary${NC}"
echo ""
echo "3. sodo    - Multi-agent, sudoers-based"
echo "   ${DIM}✓ No daemon, token auth${NC}"
echo "   ${DIM}✗ Slower, requires sudoers config${NC}"
echo ""

read -p "Select mode [1-3, default=1]: " MODE_NUM
MODE_NUM=${MODE_NUM:-1}

case $MODE_NUM in
  1) MODE="direct" ;;
  2) MODE="relay" ;;
  3) MODE="sodo" ;;
  *) echo "Invalid choice"; exit 1 ;;
esac

echo ""
echo -e "${GREEN}Selected: $MODE mode${NC}"
echo ""

# Step 2: Agent account
echo -e "${BOLD}Step 2: Agent Account${NC}"
echo ""

CURRENT_USER=$(whoami)
DEFAULT_AGENT="nas-agent"

read -p "Agent account name [default=$DEFAULT_AGENT]: " AGENT_USER
AGENT_USER=${AGENT_USER:-$DEFAULT_AGENT}

read -p "Human account (agents elevate to) [default=$CURRENT_USER]: " HUMAN_USER
HUMAN_USER=${HUMAN_USER:-$CURRENT_USER}

if ! id "$AGENT_USER" &>/dev/null; then
    echo ""
    echo "Agent account '$AGENT_USER' does not exist."
    read -p "Create it? [Y/n]: " CREATE_ACCOUNT
    CREATE_ACCOUNT=${CREATE_ACCOUNT:-Y}

    if [[ "$CREATE_ACCOUNT" =~ ^[Yy] ]]; then
        NEEDS_SUDO=1
    else
        echo "Cannot proceed without agent account. Exiting."
        exit 1
    fi
else
    NEEDS_SUDO=0
fi

echo ""

# Step 3: WSL detection
echo -e "${BOLD}Step 3: Environment Detection${NC}"
echo ""

WSL_DETECTED=0
WSL_VULNERABLE=0

if grep -qi microsoft /proc/version 2>/dev/null || [ -d /run/WSL ]; then
    WSL_DETECTED=1
    echo -e "${YELLOW}✓ WSL environment detected${NC}"

    # Check interop vulnerability
    for socket in /run/WSL/*_interop 2>/dev/null; do
        if [ -S "$socket" ]; then
            PERMS=$(stat -c %a "$socket" 2>/dev/null)
            if [ "$PERMS" = "777" ]; then
                WSL_VULNERABLE=1
                break
            fi
        fi
    done

    if [ $WSL_VULNERABLE -eq 1 ]; then
        echo -e "${RED}⚠ WSL Interop Vulnerability Detected${NC}"
        echo "Any user can execute: wsl.exe -u root"
        echo "/run/WSL/*_interop sockets have 0777 permissions"
        echo ""
        echo "Hardening options:"
        echo "1. Skip (not recommended for production)"
        echo "2. Add warning to agent prompt"
        echo ""
        read -p "Choice [1-2, default=2]: " WSL_FIX
        WSL_FIX=${WSL_FIX:-2}

        if [ "$WSL_FIX" = "2" ]; then
            WSL_ADD_WARNING=1
        else
            WSL_ADD_WARNING=0
        fi
    else
        echo -e "${GREEN}✓ Interop already hardened${NC}"
    fi
else
    echo "Native Linux/macOS environment"
fi

echo ""

# Step 4: Elevated setup
if [ $NEEDS_SUDO -eq 1 ] || [ "$MODE" != "direct" ]; then
    echo -e "${BOLD}Step 4: Elevated Setup${NC}"
    echo ""
    echo "The next steps require sudo privileges."
    echo ""
    echo -e "${YELLOW}This is your first tutorial:${NC}"
    echo "1. Open a new terminal"
    echo "2. Run: ${BOLD}tmux new -s nas-setup${NC}"
    echo "3. Inside tmux: ${BOLD}sudo -v${NC}"
    echo "4. Return here and press Enter"
    echo ""
    echo -e "${RED}If you see unexpected commands, close tmux immediately${NC}"
    echo "  (Ctrl+B, then type :kill-session and Enter)"
    echo ""
    read -p "Press Enter when ready..."
fi

# Step 5: Installation
echo ""
echo -e "${BOLD}Installing...${NC}"
echo ""

# Create agent account
if [ $NEEDS_SUDO -eq 1 ]; then
    echo "Creating agent account..."
    tmux send-keys -t nas-setup "sudo useradd -m -s /bin/bash $AGENT_USER" Enter
    sleep 2
    echo -e "${GREEN}✓ Created agent account: $AGENT_USER${NC}"
fi

# Install mode-specific components
INSTALL_DIR="/usr/local/bin"
AGENT_HOME=$(eval echo ~$AGENT_USER)

case $MODE in
  direct)
    echo "Installing direct mode (no additional binaries)..."

    # Just set config marker
    sudo -u $AGENT_USER mkdir -p "$AGENT_HOME/.config/nas"
    echo "direct" | sudo -u $AGENT_USER tee "$AGENT_HOME/.config/nas/mode" >/dev/null
    echo "human_user=$HUMAN_USER" | sudo -u $AGENT_USER tee "$AGENT_HOME/.config/nas/config" >/dev/null

    echo -e "${GREEN}✓ Direct mode configured${NC}"
    ;;

  relay)
    echo "Installing relay mode..."

    # Check for Go or offer binary download
    if ! command -v go >/dev/null; then
        echo ""
        echo -e "${YELLOW}Go not found. Relay mode requires Go to build or downloading pre-built binary.${NC}"
        echo "1. Install Go (apt install golang)"
        echo "2. Download pre-built binary (not yet available)"
        echo "3. Switch to direct/sodo mode"
        read -p "Choice [1-3]: " GO_CHOICE

        case $GO_CHOICE in
          1)
            tmux send-keys -t nas-setup "sudo apt update && sudo apt install -y golang" Enter
            sleep 10
            ;;
          2)
            echo "Pre-built binaries not yet available. Please install Go."
            exit 1
            ;;
          3)
            echo "Please restart setup and choose direct or sodo mode."
            exit 1
            ;;
        esac
    fi

    # Build nmux and nmuxd
    echo "Building relay binaries..."
    tmux send-keys -t nas-setup "cd $(pwd) && make build-relay" Enter
    sleep 5

    tmux send-keys -t nas-setup "sudo cp bin/nmux bin/nmuxd $INSTALL_DIR/" Enter
    sleep 1

    # Set config
    sudo -u $AGENT_USER mkdir -p "$AGENT_HOME/.config/nas"
    echo "relay" | sudo -u $AGENT_USER tee "$AGENT_HOME/.config/nas/mode" >/dev/null
    echo "human_user=$HUMAN_USER" | sudo -u $AGENT_USER tee "$AGENT_HOME/.config/nas/config" >/dev/null

    echo -e "${GREEN}✓ Relay mode installed${NC}"
    ;;

  sodo)
    echo "Installing sodo mode..."

    # Install shell scripts
    sudo cp scripts/nmux-sodo.sh "$INSTALL_DIR/nmux"
    sudo cp scripts/nmux-verify.sh "$INSTALL_DIR/nmux-verify"
    sudo chmod 755 "$INSTALL_DIR/nmux" "$INSTALL_DIR/nmux-verify"

    # Configure sudoers
    SUDOERS_FILE="/etc/sudoers.d/nas-sodo"
    echo "$AGENT_USER ALL=($HUMAN_USER) NOPASSWD: $INSTALL_DIR/nmux-verify" | sudo tee "$SUDOERS_FILE" >/dev/null
    sudo chmod 440 "$SUDOERS_FILE"

    # Verify sudoers syntax
    sudo visudo -c

    # Set config
    sudo -u $AGENT_USER mkdir -p "$AGENT_HOME/.config/nas"
    echo "sodo" | sudo -u $AGENT_USER tee "$AGENT_HOME/.config/nas/mode" >/dev/null
    echo "human_user=$HUMAN_USER" | sudo -u $AGENT_USER tee "$AGENT_HOME/.config/nas/config" >/dev/null

    echo -e "${GREEN}✓ Sodo mode installed${NC}"
    ;;
esac

# Generate skill
echo ""
echo "Generating /nas-elevate skill..."

SKILL_DIR="$AGENT_HOME/.claude/skills/nas-elevate"
sudo -u $AGENT_USER mkdir -p "$SKILL_DIR"

# Update MODE_MARKER in skill template
sudo -u $AGENT_USER cp skills/nas-elevate/SKILL.md "$SKILL_DIR/SKILL.md"

# Replace MODE_MARKER based on mode
case $MODE in
  direct)
    sudo -u $AGENT_USER sed -i '/<!-- MODE_MARKER_START -->/,/<!-- MODE_MARKER_END -->/c\
<!-- MODE_MARKER_START -->\
**Current installation mode: direct**\
\
No token required. Use tmux directly:\
- Human creates session: `tmux new -s work`\
- Human switches user: `su - '"$HUMAN_USER"'`\
- Agent sends commands: `tmux send-keys -t work "command" Enter`\
- Agent reads output: `tmux capture-pane -t work -p`\
<!-- MODE_MARKER_END -->' "$SKILL_DIR/SKILL.md"
    ;;

  relay|sodo)
    sudo -u $AGENT_USER sed -i '/<!-- MODE_MARKER_START -->/,/<!-- MODE_MARKER_END -->/c\
<!-- MODE_MARKER_START -->\
**Current installation mode: '"$MODE"'**\
\
Token-based access. Use nmux:\
- Human creates session: `nmux create work`\
- Human copies token to agent\
- Agent attaches: `echo "$TOKEN" | nmux attach work --token -`\
- Agent sends: `nmux send work "command"`\
- Agent reads: `nmux read work`\
<!-- MODE_MARKER_END -->' "$SKILL_DIR/SKILL.md"
    ;;
esac

echo -e "${GREEN}✓ Skill installed at $SKILL_DIR${NC}"

# WSL warning
if [ $WSL_VULNERABLE -eq 1 ] && [ $WSL_ADD_WARNING -eq 1 ]; then
    echo ""
    echo "Adding WSL warning to agent prompt..."

    WARNING_FILE="$AGENT_HOME/.claude/prompts/wsl-warning.txt"
    sudo -u $AGENT_USER mkdir -p "$(dirname $WARNING_FILE)"
    cat <<EOF | sudo -u $AGENT_USER tee "$WARNING_FILE" >/dev/null
⚠️ WSL Security Notice:
This system has a known privilege escalation vulnerability.
Do NOT use wsl.exe, cmd.exe, or powershell.exe for elevation.
Always use the /nas-elevate skill for supervised privilege requests.
EOF

    echo -e "${GREEN}✓ Warning added to $WARNING_FILE${NC}"
fi

# Step 6: Cleanup
echo ""
echo "Closing setup session..."
tmux send-keys -t nas-setup "exit" Enter 2>/dev/null || true
sleep 1

# Step 7: Complete
echo ""
echo -e "${BOLD}${GREEN}✓ Installation Complete!${NC}"
echo ""
echo -e "not-another-sandbox is installed in ${YELLOW}$MODE${NC} mode."
echo ""
echo "Next steps:"
echo "1. Close the setup session: ${BOLD}tmux kill-session -t nas-setup${NC}"
echo "2. When agents need elevation, use: ${BOLD}/nas-elevate${NC}"
echo "3. Always monitor commands in real-time"
echo ""
echo -e "${RED}⚠ Important:${NC} Check for orphan tmux sessions: ${BOLD}tmux ls${NC}"
echo ""
