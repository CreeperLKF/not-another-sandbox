<div align="center">

# not-another-sandbox (NAS)

**Not another static sandbox trying to cage your agent — an Attended Privilege Delegation mechanism built for terminal collaboration.**

*Don't build another leaky cage. Give your agent OS-native isolation by default, and lend it your terminal only while you're watching.*

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](#license)
[![Zero Compile](https://img.shields.io/badge/Build-Zero%20Compile-brightgreen.svg)](#quick-start)
[![Dependencies](https://img.shields.io/badge/Deps-bash%20%2B%20tmux-orange.svg)](#architecture)

[简体中文](README.md) | **English**

</div>

---

## Why Not Another Sandbox?

When granting permissions to coding agents (Claude Code, Codex, OpenCode, etc.), most setups swing between two extremes:

- **YOLO / Bare-metal mode**: Running the agent directly under your primary user account (often with auto-approve) — one hallucination or prompt injection can wipe code, break system configs, or touch `~/.ssh`.
- **Static sandboxes**: Wrapping everything in containers, seccomp profiles, or sprawling command allowlists — the moment you need `apt install`, `docker`, `systemd`, or `/etc` edits, you end up fighting the sandbox; worse, command allowlists are inherently brittle and easy to bypass.

**not-another-sandbox takes a different approach:**

```text
┌─────────────────────────────────────────────────────────────┐
│  Default: Agent runs under a dedicated low-priv OS user     │
│           (UID-isolated, no sudo, cannot touch your $HOME)  │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ When elevation is needed
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  Elevate: You open a supervised tmux session manually       │
│           Agent types commands · You watch live             │
│           exit / kill-session → privileges revoked at once  │
└─────────────────────────────────────────────────────────────┘
```

---

## Quick Start

```bash
git clone https://github.com/CreeperLKF/not-another-sandbox.git
cd not-another-sandbox
./install.sh          # defaults to direct mode
```

Then start your agent inside the low-privilege account:

```bash
sudo -u nas-agent -i
# Launch claude / codex / opencode here
```

Whenever the agent needs elevated privileges, it will tell you how to open a supervised session (see [Usage](#usage)).

Or let an existing agent guide you through setup: hand [skills/nas-setup-guide/SKILL.md](skills/nas-setup-guide/SKILL.md) to it.

---

## Architecture

```text
                    ┌──────────────────┐
                    │  Human Account   │  ← Daily use
                    │   (Your UID)     │
                    └────────┬─────────┘
                             │ Opens supervised session
                             │ (tmux / nmux)
                             ▼
┌─────────────────────────────────────────────────────────────┐
│                    Supervised Elevation                     │
│                                                             │
│   You watch the pane  ←→  Agent injects keys via tmux       │
│                                                             │
│   exit / kill-session  →  Privileges end immediately        │
└─────────────────────────────────────────────────────────────┘
                             ▲
                             │ Requests elevation
                             │
                    ┌────────┴─────────┐
                    │  Agent Account   │  ← Default runtime
                    │   (nas-agent)    │
                    │  Low privilege   │
                    └──────────────────┘
```

Two modes determine how the agent reaches the elevated pane:

| | `direct` (Default) | `sodo` (Advanced) |
|---|---|---|
| **Who can reach the pane** | Any process under the Agent UID | Only the agent holding the ephemeral token |
| **How human opens session** | In Agent account: `tmux new -s work`, then `su - <you>` | In Human account: `nmux create work` |
| **How agent sends keys** | `tmux send-keys ...` | `printf '%s\n' "$TOKEN" \| nmux work send-keys ...` |
| **Extra footprint** | None | `/usr/local/bin/nmux` + one `sudoers` rule |
| **Best for** | Single agent or mutually trusted agents | Multiple agents sharing one UID |

In `sodo` mode, the token lives solely in the isolated tmux server's memory and is passed via stdin (never in `argv`). Destroying the server wipes it immediately.

---

## Usage

### Day-to-Day Operation

Keep the agent inside `nas-agent`. Writing code, running tests, and routine development need no elevation.

### When Elevation Is Needed

The agent invokes `/nas-elevate` and tells you the exact command to run.

**`direct` mode** (run in the **Agent account**):

```bash
tmux new -s nginx-setup
su - <your-username>       # enter your password
# (optional) sudo -v       # if root is needed
```

The agent then drives the pane via `tmux send-keys` / `tmux capture-pane` while you watch live.

When finished: type `exit` repeatedly inside the pane, or run `tmux kill-session -t nginx-setup`.

**`sodo` mode** (run in your **Human account**):

```bash
nmux create work
# Copy the printed token to the agent, then press Enter to attach
```

The agent passes the token on stdin on every call.

When finished: type `exit` inside the pane, or run `nmux kill work`.

### Emergency Stop

```bash
tmux kill-session -t <session>     # direct
nmux kill <session>                # sodo
tmux kill-server                   # nuclear (kills all tmux sessions for current user)
```

**Detaching (`Ctrl+b d`) does NOT revoke access** — the session stays alive. Always `exit` or explicitly `kill`.

---

## Security Boundaries

NAS does not filter commands. It controls *who can cross the boundary*, keeps every crossing visible, and lets you pull the plug instantly.

| What NAS Prevents | What NAS Does Not Prevent |
|---|---|
| Agent reading `~/.ssh` or your home directory by default | Malicious commands executed inside a session you already authorized |
| Unintended privilege escalation behind your back | Kernel exploits or unhardened WSL interop bypasses (see below) |
| Forgotten elevated sessions (as long as you check `tmux ls` / `nmux ls`) | Background tasks spawned during elevation that outlive the session |

---

## WSL Hardening (Optional)

Default WSL2 creates `/run/WSL/*_interop` sockets with mode `0777` (allowing any local user to escalate via `wsl.exe -u root`) and mounts `/mnt/c` world-accessible.

NAS ships an opt-in hardening flag that preserves Windows interop and VSCode Remote-WSL for your human account:

```bash
./install.sh --harden-wsl
```

It sets up two reversible protections (both cleanly removed by `./uninstall.sh`):
1. Installs `nas-wsl-interop.{path,service}` (with `StartLimitIntervalSec=0`) to watch `/run/WSL` and tighten interop sockets to `0770` (`root:<human_group>`);
2. Configures `[automount] umask=077` in `/etc/wsl.conf` so `/mnt/*` drives are restricted to your human user and `root` (restart WSL once via `wsl.exe --terminate <Distro>` to apply, and keep shared project directories on the Linux filesystem).

This is a practical best-effort mitigation (a brief race window exists when spawning a brand-new host `wsl.exe` session), sufficient for everyday workflows. Full interop disablement (`[interop] enabled=false`) or stricter isolation must still be configured at the WSL layer.

---

## Mode Details

### `direct` (Default)

Zero extra binaries. The human opens `tmux` in the agent account, elevates with `su`, and watches. Any process under the agent UID can reach the pane — plenty for a single agent.

### `sodo` (Advanced)

Built for multiple agents sharing one UID. Each session runs in an isolated tmux server (`tmux -L nmux-<session>`) with an in-memory token. Only processes holding that token can interact with the pane. The token never touches disk and never appears in `/proc/<pid>/cmdline`.

Install:

```bash
./install.sh --mode sodo
```

Uninstall (removes `sudoers`, `nmux`, WSL hardening units, and configs without deleting the agent OS user):

```bash
./uninstall.sh
```

---

## Project Layout

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
├── docs/
│   ├── cheatsheet.md                # Human quick reference: multi-user & tmux (Chinese)
│   ├── cheatsheet.en.md             # Human quick reference: multi-user & tmux (English)
│   ├── design.md                    # Architecture & security invariants (Chinese)
│   └── design.en.md                 # Architecture & security invariants (English)
└── tests/
    ├── test-nas.sh                  # End-to-end regression suite (direct & sodo)
    └── test-wsl-harden.sh           # End-to-end WSL2 --harden-wsl suite
```

## Further Reading

- [Quick Reference for Humans (docs/cheatsheet.en.md)](docs/cheatsheet.en.md) — Multi-user basics & minimal `tmux` cheat sheet
- [Design Document (docs/design.en.md)](docs/design.en.md) — Dual-identity model, Act–Observe paradigm, security invariants, and WSL hardening details
- [Setup Guide Skill (skills/nas-setup-guide/SKILL.md)](skills/nas-setup-guide/SKILL.md)
- [Runtime Elevation Skill (skills/nas-elevate/SKILL.md)](skills/nas-elevate/SKILL.md)

## Acknowledgements & Inspiration

- **Practical inspiration**: Inspired by `remote-sudo-tmux`, bringing agent privilege delegation back to simple, transparent, revocable native `tmux` collaboration.
- **Theoretical inspiration**: Inspired by [We Query, Therefore We Compute: On Oracle Computation beyond the Machine, with an Application to Agents (arXiv:2610.09243)](https://arxiv.org/abs/2610.09243), which systematically derives how a principled Agent OS should be built.

## License

Released under the **MIT License**.
