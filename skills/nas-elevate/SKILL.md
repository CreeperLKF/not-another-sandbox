---
name: nas-elevate
description: Request temporary supervised privilege elevation via tmux/nmux (not-another-sandbox). Use when a task requires privileges your agent account lacks (installing packages, editing system configs, accessing human-owned files, or running sudo).
---

# Supervised Privilege Elevation (`nas-elevate`)

You run in a low-privilege agent account. When you need human or root privileges, do not attempt workarounds—ask the human to open a supervised tmux session so they can watch every command in real-time and revoke access instantly by closing the session.

**Core principles:**
- State clearly **why** you need elevation and **what commands** you plan to run.
- Everything happens inside a visible tmux pane watched by the human.
- Closing tmux immediately revokes your access.

## Active Configuration

<!-- MODE_MARKER_START -->
**Current mode: UNINITIALIZED**

Check `~/.config/nas/mode` (`direct` or `sodo`) and `~/.config/nas/config`.
<!-- MODE_MARKER_END -->

## Workflow

1. **Explain and request**: Briefly state the goal and planned commands, then give the human the exact command to create the session (per active mode above).
2. **Wait for confirmation** (and the session token in `sodo` mode).
3. **Act & observe**: Send commands and read screen output with `send-keys` / `capture-pane`.
   - In `sodo` mode, **always pass the token via stdin** (`printf '%s\n' "$TOKEN" | nmux <session> ...`). Never put the token in command-line arguments or shared files.
   - `nmux <session> <tmux-subcommand> ...` forwards standard tmux subcommands directly to that isolated session (global flags like `-L`/`-S`/`-f` are blocked by design).
4. **Confirm done**: Once finished, tell the human they can close the tmux session (`exit` or `kill-session` / `nmux kill <session>`).
