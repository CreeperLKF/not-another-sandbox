---
name: nas-elevate
description: Request temporary supervised privilege elevation via tmux/nmux (not-another-sandbox). Use when a task requires privileges your agent account lacks (installing packages, editing system configs, accessing human-owned files, or running sudo).
---

# Supervised Privilege Elevation (`nas-elevate`)

You run in a low-privilege agent account. When a task requires human or root privileges, do not attempt workarounds—ask the human to open a supervised tmux session so they can watch every command in real-time and revoke access by destroying the session.

## Core Rules

- **Minimal privilege**: If the task does not require elevation, do it in the agent account without asking.
- **No passwords in chat**: Never ask the human for OS/sudo passwords, private keys, or persistent credentials in chat (only the ephemeral `sodo` session token is passed when using `sodo` mode).
- **Verify before mutating**: Start with read-only checks (`id`; and `sudo -n true && echo SUDO_OK` when root is needed) inside the pane before making changes.
- **Non-interactive sudo only**: Always use `sudo -n` for root commands so an expired ticket fails fast instead of hanging at a password prompt. If a password is required, ask the human to run `sudo -v` in the attached pane.
- **Check pane state first**: Inspect the pane with `capture-pane` before sending commands. Stop and recover if the pane is inside an editor, pager (`less`), running command, or unexpected prompt. Use `--no-pager` where supported.
- **Short, auditable commands**: Keep commands short and easy for the human to audit visually. For multi-step operations, write a temporary script (in small chunks if pasting, then re-capture to verify) and run it (with `sudo -n` if root is needed).
- **Clean session hygiene**: Pick a meaningful, task-specific `<session>` name (e.g., `nginx-setup`, `docker-fix`) to avoid collisions, and never touch sessions you did not create.

## Active Configuration

<!-- MODE_MARKER_START -->
**Current mode: UNINITIALIZED**

Check `~/.config/nas/mode` (`direct` or `sodo`) and `~/.config/nas/config`.
<!-- MODE_MARKER_END -->

## Workflow

1. **Explain and request**: Briefly state the goal and planned commands, choose a meaningful `<session>` name, and give the human the exact command for the active mode above (clearly indicating which OS account terminal to run it in).
2. **Wait for confirmation** (and the ephemeral session token in `sodo` mode).
3. **Verify ready**: Capture the pane and run a read-only check (`id`, plus `sudo -n true && echo SUDO_OK` if root is required; if sudo is uncached, ask the human to run `sudo -v` in the pane).
4. **Act & observe**: Send short commands and inspect output via `capture-pane -p | tail -80`.
   - In `sodo` mode, **always pass the token via stdin** (`printf '%s\n' "$TOKEN" | nmux <session> ...`). Never put the token in argv or shared files.
   - `nmux <session> <tmux-subcommand> ...` forwards standard tmux subcommands directly to that isolated session (global flags like `-L`/`-S`/`-f` are blocked by design).
   - If a command fails after partial changes, inspect current state before retrying or rolling back.
5. **Confirm done**: Once finished, tell the human the exact `<session>` name to close (`exit` or `tmux kill-session -t <session>` / `nmux kill <session>`), noting that simply detaching leaves the session active.

<!-- WSL_WARNING_START -->
<!-- WSL_WARNING_END -->
