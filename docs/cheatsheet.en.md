# Quick Reference (For Humans)

[简体中文](cheatsheet.md) | **English**

If you don't regularly juggle Linux multi-user accounts or `tmux`, these two cheat sheets cover 99% of daily and emergency workflows.

---

## 1. OS Multi-Account Basics

Unix/Linux **multi-user isolation** is a decades-old kernel-enforced security boundary: each user gets its own UID, home directory, and file permissions. Placing an agent in a non-`sudo` account (e.g., `nas-agent`) means it cannot read your `~/.ssh`, modify system configs, or touch protected files in your home directory.

| Goal | Command | Notes |
|---|---|---|
| Check current identity | `whoami` / `id` | Shows current username, UID, and groups |
| Switch into agent account | `sudo -u nas-agent -i` | Start your coding agent inside this shell |
| Create low-priv agent user | `sudo useradd -m -s /bin/bash nas-agent` | Handled automatically by `install.sh` |
| Elevate inside tmux | `su - <your-user>` | In `direct` mode, enter your own password inside tmux |
| Grant a project dir to agent | `sudo chown -R nas-agent:nas-agent /path/to/proj` | Or share via group + `chmod g+rwX` |
| Delete agent account completely | `sudo userdel -r nas-agent` | `uninstall.sh` never deletes the user; run manually if desired |

> **Tip**: In `direct` mode, the human starts `tmux` inside the **agent account** and then runs `su - <your-user>`. In `sodo` mode, the human runs `nmux create <session>` directly in their **own human account**.

---

## 2. Minimal `tmux` Cheat Sheet

Think of `tmux` as a **shared terminal screen that both you and the agent can see**:

| Action | Command / Shortcut | Notes |
|---|---|---|
| Create session | `tmux new -s work` | Creates and attaches to session `work` |
| List active sessions | `tmux ls` | Check for forgotten sessions (`nmux ls` in `sodo` mode) |
| Re-attach | `tmux attach -t work` | Rejoin an active session (`nmux attach work` in `sodo` mode) |
| Detach temporarily | Press `Ctrl+b`, release, then `d` | Leaves view while **session stays alive** (Note: detaching ≠ revoking!) |
| Exit normally | Type `exit` or press `Ctrl+d` | Closes current shell; exit out of `su -` until tmux itself exits |
| **Emergency kill switch** | Inside: `Ctrl+b` → `:kill-session` + Enter<br>Outside: `tmux kill-session -t work` | **Spot anything suspicious? Kill the session immediately** (`nmux kill work` in `sodo` mode) |
| Kill all sessions | `tmux kill-server` | Nuclear option: terminates every tmux session for the current user |
