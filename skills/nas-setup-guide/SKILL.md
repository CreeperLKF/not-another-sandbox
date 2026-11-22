---
name: nas-setup-guide
description: Guide a human through installing and configuring not-another-sandbox (NAS) supervised privilege delegation. Referenced by the README (not installed into the agent account). Use when the user asks to set up NAS, create an isolated agent account, or configure direct/sodo privilege elevation.
---

# not-another-sandbox Setup Guide

You are helping a human (running in their normal account) install **not-another-sandbox (NAS)** so that AI agents run under a dedicated low-privilege OS user and request temporary supervised privileges when needed.

## Two Modes

1. **`direct` (default — recommended for most users)**
   - **Dependencies**: `bash` + `tmux` only.
   - **Footprint**: Zero extra binaries, zero sudoers rules.
   - **How it works**: Human creates a tmux session in the agent account (`tmux new -s work`) and elevates inside it (`su - <human>`). Agent interacts directly via `tmux send-keys` / `tmux capture-pane`.
   - **Assumption**: Single agent, or multiple agents under the same UID that mutually trust each other.

2. **`sodo` (advanced — multi-agent token isolation)**
   - **Dependencies**: `bash` + `tmux` + `sudo`.
   - **Footprint**: Single-file shell script `/usr/local/bin/nmux` (root-owned), `/etc/nas/sodo.conf`, and `/etc/sudoers.d/nas-sodo`.
   - **How it works**: Human runs `nmux create <session>` in their own account. `nmux` spawns an isolated tmux server (`tmux -L nmux-<session>`) and keeps a random token in tmux memory (`@nmux_token`). Agent passes the token via **stdin** on each call (`printf '%s\n' "$TOKEN" | nmux <session> <tmux-subcommand> ...`). Closing tmux destroys the server and token automatically.
   - **Uninstall**: Because `sodo` adds a sudoers drop-in file, inform the user that `./uninstall.sh` cleanly removes `/etc/sudoers.d/nas-sodo`, `/usr/local/bin/nmux`, `/etc/nas/`, configs, and skills (without deleting the agent user account).

## Setup Steps

### 1. Ask Minimal Questions
- **Mode**: Start by recommending `direct` unless the user runs multiple mutually untrusted agents under the same agent UID (in which case recommend `sodo` and mention `./uninstall.sh`).
- **Agent account**: Confirm whether to create a new account (default: `nas-agent`) or reuse an existing low-privilege user.
- **Human account**: Confirm target account to elevate to (default: current `$USER`).

### 2. Check Environment
- Verify `tmux` is installed (`tmux -V`).
- If on WSL (`/run/WSL/*_interop` with mode `777`), warn the user that any local user can escape isolation via `wsl.exe -u root`, and let them choose whether to add the soft prompt warning (`~/.claude/prompts/wsl-warning.txt`).

### 3. Run the Installer
Have the human run `./install.sh` (or run it inside a supervised tmux session as a live tutorial):

```bash
# Default (direct mode)
./install.sh

# Advanced (sodo mode)
./install.sh --mode sodo
```

Non-interactive flags are also supported:
```bash
./install.sh --mode direct --agent nas-agent --human "$USER" --yes
./install.sh --mode sodo   --agent nas-agent --human "$USER" --yes
```

### 4. Verify & Hand Off
Run a quick smoke test with `whoami`:
- **Direct mode**: Human opens `tmux new -s work` as `<agent>` and runs `su - <human>`; agent runs `tmux send-keys -t work "whoami" Enter` and `tmux capture-pane -t work -p`.
- **Sodo mode**: Human runs `nmux create work`, copies token to agent, attaches; agent runs `printf '%s\n' "$TOKEN" | nmux work send-keys -t work "whoami" Enter` and `printf '%s\n' "$TOKEN" | nmux work capture-pane -t work -p`.

Remind the user:
- Always close elevated tmux sessions when done (`exit` / `tmux ls` / `nmux ls`).
- To uninstall at any time: `./uninstall.sh`.
