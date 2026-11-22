<div align="center">

# not-another-sandbox (NAS)

**Not another static sandbox trying to cage your agent — an Attended Privilege Delegation mechanism built for terminal collaboration.**

*Don't build another leaky cage. Give your agent OS-native isolation by default, and lend it your terminal only while you're watching.*

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](#license)
[![Zero Compile](https://img.shields.io/badge/Build-Zero%20Compile-brightgreen.svg)](#quick-start-default-direct-mode)
[![Dependencies](https://img.shields.io/badge/Deps-bash%20%2B%20tmux-orange.svg)](#mode-comparison)

[简体中文](README.md) | **English**

</div>

---

## Why Not Another Sandbox?

When granting permissions to coding agents (Claude Code, Codex, OpenCode, etc.), most setups swing between two extremes:

- **YOLO / Bare-metal mode**: Running the agent directly under your primary user account (often with auto-approve) — one hallucination or prompt injection can wipe code, break system configs, or touch `~/.ssh`.
- **Static sandboxes**: Wrapping everything in containers, seccomp profiles, or sprawling command allowlists — the moment you need `apt install`, `docker`, `systemd`, or `/etc` edits, you end up fighting the sandbox; worse, command allowlists are inherently brittle and easy to bypass.

**not-another-sandbox takes a different approach:**

> Rely on the OS's most battle-tested primitive — **a dedicated low-privilege user account** — by default. Whenever elevated privileges are actually needed, a human opens a supervised terminal session and lends the keyboard to the agent: **fully visible in real time, and revoked the moment you `exit` or destroy the session**.

```text
  Normal (No Privileges)         Elevation (Human Present)          Done (Revoked)
┌──────────────────────┐        ┌──────────────────────────┐        ┌──────────────────────┐
│  Low-priv agent user │ ─ask─▶ │  Human opens tmux shell  │ ─exit▶ │  Session destroyed   │
│  OS-native boundary  │        │  Agent types / You watch │        │  Back to zero privs  │
└──────────────────────┘        └──────────────────────────┘        └──────────────────────┘
```

### Three Core Principles

0. **Simple to the eyes**: Zero compilation, zero containers, zero resident daemons. The entire codebase is a few hundred lines of pure shell and two skills — auditable line by line in two minutes.
1. **Before authorization, as safe as the OS itself**: Relies on native Linux/Unix UID and filesystem permission boundaries; the agent has no default escalation path.
2. **After authorization, the same power as the user**: No fragile command allowlists; safety comes from real-time human observation and instant session termination.

---

## Quick Start (Default: `direct` Mode)

**`direct` is the default and recommended mode** — zero extra binaries, zero intrusive system changes, zero uninstall burden. All you need is `bash` + `tmux`.

### Option A: Run the Installer Directly

```bash
git clone https://github.com/CreeperLKF/not-another-sandbox.git
cd not-another-sandbox
./install.sh
```

`install.sh` defaults to `direct` mode and guides you through three steps:
1. Create or select a low-privilege agent account (default: `nas-agent`);
2. Detect WSL interop privilege-escalation risks (if running under WSL);
3. Render and install the `/nas-elevate` runtime skill into the agent account (automatically using `npx skills` when available, with direct fallback).

### Option B: Let Your Current Agent Walk You Through Setup

Hand [skills/nas-setup-guide/SKILL.md](skills/nas-setup-guide/SKILL.md) to an agent running in your human account. It will interactively guide you through choosing a mode (single vs. multi-agent, WSL checks), running the installer, and completing a first smoke test.

---

## What Does Day-to-Day Usage Feel Like?

Normally, your agent stays inside `nas-agent`, writing code and running tests safely. When it hits a task that needs elevated permissions, it triggers `/nas-elevate`:

> **Agent**: I need to install `nginx` and open port 8080 (`apt update && apt install -y nginx`). Please open a supervised session:
> ```bash
> # Run in the agent account
> tmux new -s nginx-setup
> su - <your-user>
> ```
>
> **Human**: Opens a terminal, runs those two commands, enters their password, and replies "ready".
>
> **Agent** (discretely injects keystrokes and reads screen snapshots via native `tmux`):
> ```bash
> tmux send-keys -t nginx-setup "sudo -n apt update && sudo -n apt install -y nginx" Enter
> tmux capture-pane -t nginx-setup -p | tail -80
> ```
>
> **Human**: Watches every command execute live in the tmux pane; if anything looks wrong, `exit` or kill the session to cut it off immediately.
>
> **Agent**: Installation is complete — you can close `nginx-setup` now.
>
> **Human**: Types `exit` — the elevated session vanishes, and everything returns to normal.

---

## Quick Reference (For Humans)

If you don't regularly juggle Linux multi-user accounts or `tmux`, these two cheat sheets cover 99% of daily and emergency workflows.

### 1. OS Multi-Account Basics

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

### 2. Minimal `tmux` Cheat Sheet

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

---

## Setup Instructions (For Agents)

> **If you are an AI agent asked by a human to help install or configure `not-another-sandbox`, follow these steps:**

1. **Read the setup guide skill first**: Read [skills/nas-setup-guide/SKILL.md](skills/nas-setup-guide/SKILL.md) in full and walk through it interactively (never skip confirmations or touch `sudoers` without explaining the implications).
2. **Recommend `direct` by default**: Confirm the user's setup and default to zero-footprint `direct` mode; recommend `sodo` only when multiple agents share one UID and need per-session token gating, and mention `./uninstall.sh` upfront.
3. **Install and verify**: Help run `./install.sh` (including WSL interop checks when applicable) and guide the human through a minimal `whoami` elevation smoke test.
4. **Hand off clearly**: After setup, concisely explain to the human:
   - How to enter the agent account to run their agent (`sudo -u <agent> -i`);
   - Which exact commands to run when the agent triggers `/nas-elevate` in the configured mode (`direct` or `sodo`);
   - How to supervise live, close cleanly via `exit`, pull the emergency kill switch (`tmux kill-session` / `nmux kill`), and periodically check for orphan sessions (`tmux ls` / `nmux ls`).

---

## Advanced Mode: Per-Session Token Gating (`sodo` Mode)

In `direct` mode, every process under the `agent` UID can access the shared tmux socket (ideal for a single agent or mutually trusted agents).

If you run **multiple agents** under the same low-privilege account and want **only the agent holding the current ephemeral token** to interact with the elevated session, enable `sodo` (*super-oracle do*) mode (see [docs/design.en.md](docs/design.en.md) for detailed isolation boundaries):

### Installation

```bash
./install.sh --mode sodo
```

Still **zero-compile** (requires only `bash` + `tmux` + `sudo`) and installs just three minimal files:
- `/usr/local/bin/nmux` — single-file pure shell gatekeeper (`root:root`, `0755`)
- `/etc/nas/sodo.conf` — trusted `HUMAN_USER` / `AGENT_USER` config (`root:root`, `0644`)
- `/etc/sudoers.d/nas-sodo` — allows `agent` passwordless execution of `/usr/local/bin/nmux` as `human` only (with `env_reset`)

### Workflow

```bash
# 1. Human creates an isolated session in the human account
nmux create work
# Session: work
# Token:   e7660c53-c9ba-4006-9b45-013fdf30f80b
# Copy the token to the target agent, then press Enter to attach and supervise

# 2. Agent passes the token via stdin on every call; full tmux subcommands forwarded
printf '%s\n' "$TOKEN" | nmux work send-keys -t work "id" Enter
printf '%s\n' "$TOKEN" | nmux work capture-pane -t work -p | tail -80

# 3. Human destroys the session (exit inside pane or nmux kill work)
# The isolated tmux server exits, destroying the in-memory token with zero leftover files
```

### How `sodo` Holds the Boundary

- **Tokens never touch disk**: Each session runs in an isolated `tmux -L nmux-<session>` server; the random UUID lives solely in that server's RAM (`@nmux_token`), not even `/dev/shm`. Destroying the server wipes it immediately.
- **Tokens never enter `ps` / `cmdline`**: Both creation (`tmux source-file -` via stdin) and agent invocation (stdin through `sudo -n`) keep the token out of every child process's `argv` and `/proc/<pid>/cmdline`.
- **No command allowlist, yet escape-proof**: Strict session name regex (blocks `../` path traversal and fake tmux server spoofing) and strict subcommand validation (blocks `-L`/`-S`/`-f` global flags to prevent escaping to the human's personal tmux or reading arbitrary files), while forwarding all tmux subcommands freely.
- **Clean, reversible uninstall**: Run `./uninstall.sh` anytime to remove `sudoers`, `/usr/local/bin/nmux`, configs, skills, and active sessions (without deleting the agent OS account).

---

## Mode Comparison

| Dimension | `direct` (Default) | `sodo` (Advanced) |
|---|---|---|
| **Use case** | Single agent / mutually trusted agents | Multi-agent per-session token gating under one UID |
| **Dependencies** | `bash` + `tmux` | `bash` + `tmux` + `sudo` |
| **Extra components** | None (native `tmux`) | Single-file shell script `/usr/local/bin/nmux` |
| **System footprint** | Zero | 1 drop-in `/etc/sudoers.d/nas-sodo` (with `uninstall.sh`) |
| **Auth & isolation** | OS-native UID boundary | Isolated `tmux -L` + RAM `@nmux_token` + stdin token |
| **Revocation** | Destroy tmux session | Destroy tmux server (exits server & wipes token) |

---

## Security Boundaries & Honest Trade-offs

We prefer putting assumptions and limits in plain sight:

1. **No command filtering — human eyes are the backstop**: NAS controls *who* crosses the boundary, keeps execution visible, and gives you an instant kill switch. It does not promise to block malicious flags via allowlists. In `sodo` mode, an agent holding a valid token has full tmux control over that session.
2. **Known WSL bypass surface**: Under default WSL2, `/run/WSL/*_interop` sockets are `0777`, allowing any local user to bypass Linux account isolation via `wsl.exe -u root`. `install.sh` detects this and can patch a soft notice into `/nas-elevate`; for a hard boundary, disable WSL interop or harden `/init`.
3. **Watch out for orphan sessions (`detach` ≠ destroy)**: Closing a terminal tab or pressing `Ctrl+b d` only *detaches* the client — the session stays alive in the background. Always end sessions via `exit` or `nmux kill <session>` (and check with `tmux ls` / `nmux ls`).

---

## In Development

- **WSL Interop Patch**: An out-of-the-box hardening patch for the default WSL2 `0777` `/run/WSL/*_interop` socket bypass, blocking low-privilege agent escape paths while keeping Windows interop usable for the human account.

---

## Project Layout

Small enough to read end-to-end in a few minutes:

```text
not-another-sandbox/
├── README.md                        # Chinese README
├── README.en.md                     # English README (this file)
├── install.sh                       # Interactive / non-interactive installer (default: direct)
├── uninstall.sh                     # Clean uninstaller
├── scripts/
│   └── nmux                         # Single-file shell wrapper for sodo mode
├── skills/
│   ├── nas-setup-guide/SKILL.md     # Setup guide skill (for human-side agent)
│   └── nas-elevate/SKILL.md         # Runtime elevation skill (installed into agent account)
└── docs/
    ├── design.md                    # Architecture & security invariants (Chinese)
    └── design.en.md                 # Architecture & security invariants (English)
```

## Further Reading

- [Design Document (docs/design.en.md)](docs/design.en.md) — Dual-identity model, Act–Observe paradigm, security invariants, isolation boundaries, and WSL hardening
- [Setup Guide Skill (skills/nas-setup-guide/SKILL.md)](skills/nas-setup-guide/SKILL.md)
- [Runtime Elevation Skill (skills/nas-elevate/SKILL.md)](skills/nas-elevate/SKILL.md)

## Acknowledgements & Inspiration

- **Practical inspiration**: Inspired by `remote-sudo-tmux`, bringing agent privilege delegation back to simple, transparent, revocable native `tmux` collaboration.
- **Theoretical inspiration**: Inspired by [We Query, Therefore We Compute: On Oracle Computation beyond the Machine, with an Application to Agents (arXiv:2610.09243)](https://arxiv.org/abs/2610.09243), which systematically derives how a principled Agent OS should be built.

## License

Released under the **MIT License**.
