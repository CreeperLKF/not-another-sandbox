#!/bin/bash
# nmux for sodo mode - token-based tmux wrapper with sudoers verification

set -e

MODE=$(cat ~/.config/nas/mode 2>/dev/null || echo "unknown")
HUMAN_USER=$(grep human_user ~/.config/nas/config 2>/dev/null | cut -d= -f2)

case "$1" in
  create)
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
    ;;

  attach)
    SESSION="$2"
    TOKEN_FLAG="$3"

    if [ "$TOKEN_FLAG" = "--token" ]; then
      if [ "$4" = "-" ]; then
        # Read from stdin
        read -r TOKEN
      else
        TOKEN="$4"
      fi
    else
      echo "Usage: nmux attach <session-name> --token <token|->"
      exit 1
    fi

    # Verify via sudo
    sudo /usr/local/bin/nmux-verify "$SESSION" "$TOKEN" verify
    echo "Attached to session: $SESSION"
    ;;

  send)
    SESSION="$2"
    shift 2
    COMMAND="$*"

    # Token should be in environment or passed separately
    # For simplicity, verify via sudo
    sudo /usr/local/bin/nmux-verify "$SESSION" "$NAS_TOKEN" send "$COMMAND"
    ;;

  read)
    SESSION="$2"
    sudo /usr/local/bin/nmux-verify "$SESSION" "$NAS_TOKEN" read
    ;;

  list)
    tmux list-sessions 2>/dev/null || echo "No active sessions"
    ;;

  *)
    echo "Usage: nmux {create|attach|send|read|list} [args...]"
    exit 1
    ;;
esac
