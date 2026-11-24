# not-another-sandbox (NAS) / nmux — Design Document

[简体中文](design.md) | **English**

> **Not another static sandbox trying to cage an agent — an Attended Privilege Delegation mechanism built for terminal collaboration.**

---

## 1. Core Philosophy

### The Dilemma & Trade-off

Coding agents face a classic permission dilemma in daily development and system administration:
- **Static sandboxes are too rigid**: They get in the way of routine tasks like installing packages or editing system configs, while command allowlists are fragile and expensive to maintain.
- **Direct host privileges are too loose**: Any hallucination or prompt injection can immediately affect the host system.

NAS adopts a pragmatic middle ground:
- **OS-native isolation by default**: The agent runs under a dedicated low-privilege OS account with zero default escalation paths.
- **Human-attended elevation on demand**: A human opens a supervised terminal session and temporarily delegates input to the agent — visible in real time and revocable by destroying the session.

### Three Basic Principles

0. **Simple to the eyes**: Zero compile dependencies; straightforward enough for anyone to audit line by line in minutes.
1. **Before authorization, as safe as the OS itself**: Backed by native OS UID and filesystem permission boundaries.
2. **After authorization, the same power as the user**: No brittle subcommand allowlists; risk control rests on real-time human supervision and instant termination.

---

## 2. Architectural Abstractions

### Privilege Hierarchy

```text
root  (UID 0)      ← System administrator
  ↓
human (UID 1000)   ← Human daily account (elevation target; human may further sudo inside the pane)
  ↓
agent (UID 1001+)  ← Agent runtime account, unprivileged by default
```

### Orthogonal Dual-Identity Model

- **Execution Identity**: The kernel-enforced terminal execution subject (`human` or `root`) that determines what commands can actually do.
- **Input Principal**: Whoever injects keystrokes into that terminal (the human, or a specific agent holding a valid session token).

The human always owns and observes the underlying session; the agent only receives temporary delegation to send discrete inputs and read screen snapshots while the session is alive.

### Discrete Act–Observe Paradigm

Reuses native `tmux` terminal emulation and state management directly:
- **Act**: `send-keys` injects commands
- **Observe**: `capture-pane -p` captures plain-text screen snapshots

No custom streaming PTY proxy and no parallel command grammar to maintain alongside `tmux`.

---

## 3. Two Operating Modes

NAS ships with a **zero-dependency default mode** and an **advanced per-session token mode**:

| Property | `direct` (Default) | `sodo` (Advanced) |
|---|---|---|
| **Isolation boundary** | OS-native user & tmux socket (`0700`) | `sudoers` + isolated tmux server + RAM token |
| **Extra components** | None (native `tmux` directly) | Single-file shell `/usr/local/bin/nmux` |
| **System config** | None | `/etc/nas/sodo.conf` + `/etc/sudoers.d/nas-sodo` |
| **Multi-agent gating** | None (mutually trusted within UID) | Yes (only holders of the session token can access that session) |
| **Dependencies** | `bash` + `tmux` | `bash` + `tmux` + `sudo` |
| **Credential lifecycle** | No credentials; ends when tmux closes | Lives in tmux server RAM; destroyed when server exits |

### 3.1 `direct` Mode (Default)

Ideal for a single agent or mutually trusted agents on the same machine:

```text
Human (in agent account):
  $ tmux new -s work
  $ su - <human>          # Elevate to human account inside tmux (and sudo -v if needed)

Agent (in agent account):
  $ tmux send-keys -t work "<command>" Enter
  $ tmux capture-pane -t work -p | tail -80

Human finishes supervising:
  $ exit                  # Exit tmux; privilege ends immediately
```

### 3.2 `sodo` Mode (Advanced: Per-Session Token Gating)

When multiple agents share the same `agent` UID, `sodo` (*super-oracle do*) uses a **single-file `/usr/local/bin/nmux`** for cross-user verification and passthrough:

```text
Human (in human account):
  $ nmux create work
    -> Starts isolated tmux server: tmux -L nmux-work new-session -d -s work
    -> Generates short random token (XXXX-XXXX, 40-bit unambiguous alphabet), writes @nmux_token into server RAM via stdin (`tmux source-file -`, never in argv)
    -> Prints token; human copies it to target agent and presses Enter to attach and supervise

Agent (in agent account):
  $ printf '%s\n' "$TOKEN" | nmux work send-keys -t work "<command>" Enter
    -> nmux detects agent user and re-execs:
       exec sudo -n -u <human> /usr/local/bin/nmux work send-keys -t work ...
       (stdin passes untouched through sudo; token never enters command-line arguments)
    -> Elevated nmux (sees non-empty SUDO_USER, always enters agent verification path):
       1. Validates session name regex and tmux subcommand format (blocks -L/-S/-f global flags)
       2. Reads first line from stdin as token
       3. Compares against `tmux -L nmux-work show-option -gqv @nmux_token`
       4. On match, runs `exec tmux -L nmux-work "$@"`

Human finishes supervising:
  $ exit or nmux kill work
    -> Isolated tmux server (nmux-work) exits
    -> /tmp/tmux-<human_uid>/nmux-work and in-memory @nmux_token vanish with zero residue
```

---

## 4. Security Invariants (`sodo` Mode)

1. **Tamper-Resistant Trust Root**
   - `/usr/local/bin/nmux` and `/etc/nas/sodo.conf` are owned by `root:root` and unwritable by the agent. On startup, `nmux` verifies the config file is not a symlink, is owned by `root`, and has no group/world write bits.
   - `nmux` runs with `#!/bin/bash -p`, hardcoded `PATH`, `unset TMUX TMUX_TMPDIR`, and `Defaults!/usr/local/bin/nmux env_reset` in sudoers to defend against environment injection (`BASH_ENV`, `TMUX_TMPDIR`, etc.).
   - Whenever `SUDO_USER` is non-empty, `nmux` unconditionally routes to the untrusted agent verification path, preventing abuse of human management subcommands (`create`, `kill`, etc.) via sudo.

2. **Zero Command-Line Credential Leakage**
   - Processes under the same UID (and other local users under Linux's default `hidepid=0`) can read `/proc/<pid>/cmdline`.
   - On creation, `nmux` uses the bash builtin `printf` piped into `tmux -L "$socket" source-file -` to set `@nmux_token`; on invocation, it reads the token strictly from **stdin** and invokes `sudo -n` (non-interactive). The token never appears in any child process's `argv` across its entire lifecycle.

3. **Session Name Injection & Cross-Session Escape Prevention**
   - `<session>` must match `^[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}$`, preventing `../` path traversal (which could otherwise target a rogue agent-owned tmux server) and tmux target delimiter injection.
   - The first forwarded argument must match `^[a-z][a-z0-9-]*$`, completely blocking global tmux flags (`-L`, `-S`, `-f`, etc.) so an agent cannot redirect to the human's personal tmux server or parse arbitrary files, while preserving unrestricted passthrough of tmux subcommands.

4. **Credentials Live and Die with the Session**
   - No `/dev/shm` or on-disk token files; the token exists exclusively in the isolated tmux server's memory. There is no separate `revoke` command — destroying the tmux server invalidates the token immediately.

5. **Explicit Design Boundaries**
   - **Admitted means full control (no allowlist)**: Once an agent holds a valid token, it can issue any tmux subcommand to `nmux-<session>` (including non-visible subcommands like `run-shell`, equivalent to the authorized `human` session). Defense relies on strict entry control, cross-session isolation, human attendance, and instant server destruction.
   - **Shared-UID multi-agent boundary (transitional model)**: `sodo` is a **per-session token gate (transitional security measure)** for multiple agents sharing one UID, preventing unauthorized agents from piggybacking on a shared tmux socket or accidentally interfering with an active session. Because processes sharing one Linux UID still share the same home directory (including chat transcripts, configs, and shell profiles), token delivery and storage depend on the surrounding runtime environment. For strong adversarial isolation between mutually untrusted agents, assign **separate OS accounts** to return to native UID isolation.
   - **Revocation semantics (`detach` vs. `exit` / `nmux kill`)**: Closing a terminal window or pressing `Ctrl+b d` only *detaches* the client — the tmux server and token stay alive. Only exiting all shells inside the session (`exit`) or running `nmux kill <session>` destroys the server and invalidates the old token for future requests. Consistent with "same power as the user after authorization", destroying the server does not roll back completed system modifications or detached background jobs.
   - **Install & uninstall privilege boundaries**: `install.sh` supports idempotent in-place reinstalls/upgrades within the same mode, and blocks switching from `sodo` back to `direct` while old `sudoers`/`nmux` artifacts remain (prompting the user to run `./uninstall.sh` first so mode and actual privileges never diverge). When `npx` is present in the agent account, `install.sh` and `uninstall.sh` delegate `/nas-elevate` skill management to `npx skills` as `AGENT_USER`, falling back cleanly to `~/.claude/skills/nas-elevate`. `uninstall.sh` uses `root` only for system-owned files and cleans all agent-home paths strictly as `AGENT_USER`.

---

## 5. WSL Hardening (`--harden-wsl`, Optional)

Default WSL2 ships with two cross-boundary exposures that bypass native Linux multi-user isolation:
1. **World-writable interop sockets**: `/run/WSL/*_interop` sockets are created by `/init` as `root:root` with mode `0777`. Even without `$WSL_INTEROP` in its environment, any unprivileged Linux user can enumerate `/run/WSL/*_interop` and invoke Windows-side `wsl.exe -u root`.
2. **World-accessible Windows drives**: `/mnt/c`, `/mnt/d`, and other `drvfs` (`9p`) mounts default to mode `0777` without a `umask`, letting low-privilege users read/write host user profiles (`/mnt/c/Users/<user>`) or execute Windows binaries directly.

NAS provides an opt-in `--harden-wsl` flag in `install.sh` (compatible with both `direct` and `sodo` modes, and cleanly reversible via `uninstall.sh`):

- **Runtime `/run/WSL/*_interop` lockdown (`0770 root:<group>`)**:
  - Installs `nas-wsl-interop.path` (`PathChanged=/run/WSL`) and `nas-wsl-interop.service` (triggered at `multi-user.target` boot and on `/run/WSL` changes, both with `StartLimitIntervalSec=0` so rapid session bursts never trip systemd start-limit throttling).
  - Rather than running a naive `chmod o=` (which locks out the human user as well because `/init` owns all `*_interop` sockets as `root:root`), NAS sets the socket group to the human's exclusive primary group (or a dedicated `nas-interop` system group if the primary group is shared) with mode `0770`.
  - Effect: Human terminals, `root`, and VSCode Remote-WSL retain full Windows interop with zero runtime overhead during Linux→Windows `.exe` calls (`connect()` does not modify `/run/WSL`), while the unprivileged `agent` receives kernel `EACCES` on every interop socket.
- **Mount-level `/mnt/*` lockdown (`umask=077`)**:
  - Configures `[automount] options = "uid=<human_uid>,gid=<human_gid>,umask=077"` in `/etc/wsl.conf` (preserving any pre-existing custom `options` with a warning rather than overwriting).
  - Once the WSL distro restarts, Windows drives mount as `0700`: both the human user and `root` (via `9p` `access=client` + `CAP_DAC_OVERRIDE`) retain full access, while the `agent` cannot read/write Windows files or execute `/mnt/c/.../wsl.exe` (shared agent workspaces must live on the Linux filesystem).
- **Explicit Boundaries (Best-Effort Scope & Race Preconditions)**:
  - Runtime socket hardening is **best-effort**: whenever a brand-new `wsl.exe` session is spawned from the Windows host, the newly created `<pid>_interop` socket has a brief (~tens of ms) TOCTOU window before systemd applies `0770`. Exploiting this window in practice requires **all three** preconditions simultaneously:
    1. **Active polling agent**: The agent process is already running and actively polling `/run/WSL` in a tight millisecond loop (under normal startup order — booting WSL / connecting VSCode first and launching the agent inside `nas-agent` afterwards — existing sockets are already `0770` with zero race);
    2. **New host-side `wsl.exe` invocation**: A brand-new `wsl.exe` process is launched from Windows while the loop is running (opening panes in `tmux` / `nmux` or opening integrated terminal tabs inside an already-connected VSCode Server forks directly inside Linux and **never creates a new interop socket**);
    3. **Viable payload**: Once `/mnt/*` `umask=077` is active after a WSL restart, `agent` cannot access or execute `/mnt/c/.../wsl.exe`, so an attacker would also have to speak the undocumented binary WSL interop protocol directly over raw `AF_UNIX` within that brief window.
  - **Test coverage scope**: The automated regression suite (`tests/test-wsl-harden.sh`) and accompanying test reports verify steady-state permission isolation, rapid-burst resilience, and clean rollback only; **they intentionally do not cover adversarial TOCTOU race-window testing**.
  - If WSLg GUI support is enabled, X11/Wayland sockets under `/mnt/wslg` remain shared (`guiApplications=false` in host `.wslconfig` disables WSLg if needed); for a hard air-gap, set `[interop] enabled=false` in `/etc/wsl.conf`.
  - When `--harden-wsl` is not enabled, `install.sh` still offers to patch a soft notice into the `/nas-elevate` skill (`--wsl-warning`).

---

## 6. Repository Structure

```text
not-another-sandbox/
├── README.md                        # Quick start (Chinese)
├── README.en.md                     # Quick start (English)
├── install.sh                       # Interactive / non-interactive installer
├── uninstall.sh                     # Clean removal of sudoers, nmux, WSL hardening, configs, and skill
├── scripts/
│   └── nmux                         # Single-file pure shell entrypoint for sodo mode
├── skills/
│   ├── nas-setup-guide/SKILL.md     # Setup guide skill (referenced by README, not installed)
│   └── nas-elevate/SKILL.md         # Runtime elevation skill (rendered per mode during install)
├── docs/
│   ├── cheatsheet.md                # Human quick reference: multi-user & tmux (Chinese)
│   ├── cheatsheet.en.md             # Human quick reference: multi-user & tmux (English)
│   ├── design.md                    # Architecture & security invariants (Chinese)
│   └── design.en.md                 # This document (English)
└── tests/
    ├── test-nas.sh                  # End-to-end regression suite (direct & sodo)
    └── test-wsl-harden.sh           # End-to-end WSL2 --harden-wsl suite
```
