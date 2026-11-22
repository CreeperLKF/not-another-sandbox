#!/bin/bash
# nmux for sodo mode - token-based tmux wrapper with sudoers verification
# Principle: verify token, then forward everything to tmux (no command whitelist)

set -e

MODE=$(cat ~/.config/nas/mode 2>/dev/null || echo "unknown")
HUMAN_USER=$(grep human_user ~/.config/nas/config 2>/dev/null | cut -d= -f2)

# Special case: create generates token
if [ "$1" = "create" ]; then
  SESSION="$2"
  if [ -z "$SESSION" ]; then
    echo "Usage: nmux create <session-name>"
    exit 1
  fi

  # Generate token
  TOKEN=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)

  # Store token
  TOKEN_FILE="/dev/shm/nmux-$SESSION"
  echo "$TOKEN" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"

  # Create tmux session
  tmux new-session -d -s "$SESSION"
  tmux send-keys -t "$SESSION" "su - $HUMAN_USER" Enter

  echo "Session created: $SESSION"
  echo "Token: $TOKEN"
  echo ""
  echo "Share this token with the agent to grant access."
  exit 0
fi

# Special case: auth reads token from stdin and sets NAS_TOKEN
if [ "$1" = "auth" ]; then
  SESSION="$2"
  if [ -z "$SESSION" ]; then
    echo "Usage: echo <token> | nmux auth <session-name>"
    exit 1
  fi
  read -r TOKEN

  # Verify token via sudo
  sudo /usr/local/bin/nmux-verify "$SESSION" "$TOKEN" verify

  # Export for subsequent commands in same shell
  export NAS_TOKEN="$TOKEN"
  export NAS_SESSION="$SESSION"
  echo "Authenticated to session: $SESSION"
  echo "Use 'nmux <tmux-commands>' to interact with the session"
  exit 0
fi

# All other commands: verify token, then forward to tmux
if [ -z "$NAS_TOKEN" ]; then
  echo "Error: Not authenticated. Run: echo <token> | nmux auth <session>" >&2
  exit 1
fi

if [ -z "$NAS_SESSION" ]; then
  echo "Error: No session set. Run: echo <token> | nmux auth <session>" >&2
  exit 1
fi

# Verify and execute
sudo /usr/local/bin/nmux-verify "$NAS_SESSION" "$NAS_TOKEN" exec -- tmux "$@"
