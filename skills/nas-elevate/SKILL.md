---
name: nas-elevate
description: Request privilege elevation through supervised tmux sessions. Use when you need elevated permissions (installing packages, modifying system config, accessing protected files) that your agent account lacks. Also when the user mentions sudo, root access, or system administration.
---

# Supervised Privilege Elevation

Request temporary elevated privileges under human supervision via the not-another-sandbox (NAS) system.

## What This Is

You run in a low-privilege agent account. When you need higher permissions, you ask the human to open a supervised session. The human watches every command in real-time and can terminate access instantly by closing the session.

**Key principles:**
- Explain why you need elevation and what you'll do
- The human sees everything you send
- Session closes = access revoked

## What This Is

You run in a low-privilege agent account. When you need higher permissions, you ask the human to open a supervised session. The human watches every command in real-time and can terminate access instantly by closing the session.

**Key principles:**
- Explain why you need elevation and what you'll do
- The human sees everything you send
- Session closes = access revoked

## Installation Mode

<!-- MODE_MARKER_START -->
**Current mode: UNINITIALIZED**
<!-- MODE_MARKER_END -->

Check the mode if needed:
```bash
cat ~/.config/nas/mode 2>/dev/null || echo "direct"
```

## Request Pattern

**1. Explain your need:**
```
I need elevated privileges to install build-essential and configure ufw:
  apt update && apt install -y build-essential
  ufw allow 8080/tcp && ufw enable
Could you create a session for me?
```

**2. Wait for token** (if relay/sodo) or confirmation (if direct)

**3. Use the session:**

### Direct mode
```bash
tmux send-keys -t work "apt update" Enter
tmux capture-pane -t work -p
```

### Relay/sodo mode
```bash
echo "$TOKEN" | nmux send-keys -t work "apt update" Enter
echo "$TOKEN" | nmux capture-pane -t work -p
```

**4. Confirm completion:**
```
Done with the installation. You can close the session now.
```

That's it. Explain need, get access, work, confirm done.
# Send a command
tmux send-keys -t work "apt update" Enter

# Read the output
tmux capture-pane -t work -p
```

### For Token-Based Mode (relay/sodo)

## Request Pattern

**1. Explain your need:**
```
I need elevated privileges to install build-essential and configure ufw:
  apt update && apt install -y build-essential
  ufw allow 8080/tcp && ufw enable
Could you create a session for me?
```

**2. Wait for token** (if relay/sodo) or confirmation (if direct)

**3. Use the session:**

### Direct mode
```bash
tmux send-keys -t work "apt update" Enter
tmux capture-pane -t work -p
```

### Relay/sodo mode
```bash
echo "$TOKEN" | nmux send-keys -t work "apt update" Enter
echo "$TOKEN" | nmux capture-pane -t work -p
```

**4. Confirm completion:**
```
Done with the installation. You can close the session now.
```

That's it. Explain need, get access, work, confirm done.
