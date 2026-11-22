#!/bin/bash
# nmux-verify - Token verification for sodo mode (called via sudo)

SESSION="$1"
TOKEN="$2"
ACTION="$3"
shift 3

TOKEN_FILE="/dev/shm/nmux-$SESSION"

# Verify token
if [ ! -f "$TOKEN_FILE" ]; then
  echo "Error: Session not found or token expired" >&2
  exit 1
fi

STORED_TOKEN=$(cat "$TOKEN_FILE")
if [ "$TOKEN" != "$STORED_TOKEN" ]; then
  echo "Error: Invalid token" >&2
  exit 1
fi

# Execute action
case "$ACTION" in
  verify)
    # Just verification, already passed
    exit 0
    ;;

  send)
    COMMAND="$*"
    tmux send-keys -t "$SESSION" "$COMMAND" Enter
    ;;

  read)
    tmux capture-pane -t "$SESSION" -p
    ;;

  exec)
    # Execute arbitrary command after token verification
    # Expects: nmux-verify <session> <token> exec -- <command> [args...]
    exec "$@"
    ;;

  *)
    echo "Error: Unknown action: $ACTION" >&2
    exit 1
    ;;
esac
