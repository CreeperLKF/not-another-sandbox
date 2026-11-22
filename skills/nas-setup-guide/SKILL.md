---
name: nas-setup-guide
description: Guide for installing and configuring the not-another-sandbox (NAS) privilege delegation system. Use this when the user asks about setting up NAS, installing privilege delegation for agents, configuring agent accounts, or mentions they want to set up supervised elevation. This skill is referenced by the README but not installed—it guides the agent through helping the human make configuration choices.
---

# not-another-sandbox Setup Guide

This skill guides you through helping the user install and configure the NAS privilege delegation system. You are acting as an installation assistant—ask questions, explain options, and execute the setup process.

## Your Role

You're helping the human set up a system that will later allow *other* agents (or yourself in future sessions) to request temporary elevated privileges under supervision. Walk them through decisions, explain tradeoffs, and execute the installation.

## Setup Flow Overview

1. **Understand their environment** (single vs multi-agent, trust model)
2. **Choose installation mode** (direct/relay/sodo)
3. **Configure agent account** (create new or use existing)
4. **Detect and offer WSL hardening** (if applicable)
5. **Execute privileged installation steps** (via supervised tmux)
6. **Generate runtime skill** (/nas-elevate) based on chosen mode
7. **Test and verify** the installation

## Phase 1: Discovery

Ask the user:

### Environment Questions

1. **How many agents will use this system?**
   - Single agent (just Claude, or one other agent) → **direct mode** is simplest
   - Multiple different agents → **relay** or **sodo** for isolation

2. **Do you trust all agents equally?**
   - Yes, they're all mine / same codebase → **direct mode** acceptable
   - No, some are third-party or experimental → **relay** or **sodo** required

3. **Do you want a background daemon?**
   - No preference / yes → **relay** (cleaner security boundary)
   - No, prefer zero daemons → **sodo** (uses sudoers)

### Account Questions

4. **Agent account setup:**
   - "Do you already have a dedicated account for agents?" 
   - If yes: "What's the username?"
   - If no: "I'll create one. What should we name it? (suggestion: `nas-agent`)"

5. **Your username (the 'human' account):**
   - Usually detected from `$USER` or `whoami`
   - Confirm: "You're currently logged in as `<username>`. Is this the account agents should elevate to?"

### Environment Detection

Check automatically:

```bash
# Detect WSL
if grep -qi microsoft /proc/version 2>/dev/null || [ -d /run/WSL ]; then
    echo "WSL detected"
    # Check interop vulnerability
    if [ -S /run/WSL/*_interop ] && [ $(stat -c %a /run/WSL/*_interop 2>/dev/null | head -n1) = "777" ]; then
        echo "Interop vulnerability present (0777 permissions)"
    fi
fi

# Detect systemd
if pidof systemd >/dev/null; then
    echo "systemd available"
fi

# Check for existing tmux
if command -v tmux >/dev/null; then
    echo "tmux found: $(tmux -V)"
else
    echo "tmux NOT installed (will need to install)"
fi
```

## Phase 2: Present Mode Recommendations

Based on their answers, recommend a mode:

### Recommendation Matrix

| Scenario | Recommended Mode | Why |
|----------|-----------------|-----|
| Single agent, trusted | **direct** | Simplest, no overhead |
| Multiple agents, all trusted | **direct** | Simple, assumes cooperative behavior |
| Multiple agents, some untrusted | **relay** | Strong isolation, daemon handles auth |
| Multiple agents, no daemon wanted | **sodo** | Isolation via sudoers, but slower |
| Testing/evaluation phase | **direct** | Start simple, can upgrade later |

Present your recommendation:

> "Based on your setup (single agent, all trusted), I recommend **direct mode**. This is the simplest option—no extra binaries or daemons needed, just direct tmux usage.
>
> Tradeoffs:
> - ✓ Zero installation footprint
> - ✓ No performance overhead
> - ✗ Any agent with the same UID can attach to sessions (requires trust)
>
> Want to proceed with direct mode, or explore relay/sodo?"

## Phase 3: WSL Hardening (if applicable)

If WSL is detected with the interop vulnerability:

> "⚠️ WSL Interop Vulnerability Detected
> 
> Currently, any user on this system can execute `wsl.exe -u root` to become root, bypassing all restrictions. This is because `/run/WSL/*_interop` sockets have 0777 permissions.
>
> **Option 1: Patch /init** (recommended, technical)
> - Recompile WSL's `/init` binary to restrict interop to specific users
> - Requires compiling from source (20-30 minutes)
> - Survives until WSL updates (can automate re-patching)
>
> **Option 2: Add prompt warning** (quick, less secure)
> - Edit the agent's system prompt to warn against using `wsl.exe` for elevation
> - Relies on agent compliance (prompt injection risk)
>
> **Option 3: Skip** (not recommended for production)
> - Continue with the vulnerability present
> - Only suitable for trusted single-agent environments
>
> What would you like to do?"

If they choose patching, note: "We'll handle this at the end of setup, as it requires elevated access."

## Phase 4: Prepare for Privileged Setup

Explain the supervised setup process:

> "The next steps require elevated privileges to:
> - Create agent account (if needed)
> - Install nmux binary (if relay/sodo mode)
> - Configure sudoers (if sodo mode)
> - Set up systemd services (if relay mode)
>
> **This is your first hands-on tutorial of how NAS works:**
>
> 1. Open a new terminal
> 2. Run: `tmux new -s nas-setup`
> 3. Inside tmux, run: `sudo -v` (authenticate once)
> 4. Return here and type 'ready'
>
> I'll send commands to that tmux session. **If you see anything unexpected, close tmux immediately** with Ctrl-B, then type `:kill-session` and Enter.
>
> This is exactly how you'll supervise agents later—you watch commands in real-time and can stop them instantly."

Wait for user confirmation before proceeding.

## Phase 5: Execute Installation

Once user confirms ready, execute based on mode:

### For All Modes: Agent Account

If creating a new agent account:

```bash
# Check if account exists
tmux send-keys -t nas-setup "id nas-agent 2>/dev/null || echo 'DOES_NOT_EXIST'" Enter
sleep 1
tmux capture-pane -t nas-setup -p

# If doesn't exist, create it
tmux send-keys -t nas-setup "sudo useradd -m -s /bin/bash nas-agent" Enter
sleep 1

# Verify
tmux send-keys -t nas-setup "id nas-agent" Enter
sleep 1
tmux capture-pane -t nas-setup -p
```

### For Direct Mode Only

Direct mode needs no additional installation. Skip to Phase 6.

### For Relay Mode

```bash
# Install Go if not present (needed to build nmux)
tmux send-keys -t nas-setup "which go || sudo apt install -y golang" Enter
sleep 5
tmux capture-pane -t nas-setup -p

# Clone and build
tmux send-keys -t nas-setup "cd /tmp && git clone <repo-url>" Enter
sleep 3

tmux send-keys -t nas-setup "cd /tmp/not-another-sandbox && make build" Enter
sleep 10

# Install binaries
tmux send-keys -t nas-setup "sudo cp bin/nmux bin/nmuxd /usr/local/bin/" Enter
sleep 1

tmux send-keys -t nas-setup "sudo chmod 755 /usr/local/bin/nmux /usr/local/bin/nmuxd" Enter
sleep 1

# Create config directory for agent
tmux send-keys -t nas-setup "sudo -u nas-agent mkdir -p /home/nas-agent/.config/nas" Enter
sleep 1

tmux send-keys -t nas-setup "echo 'relay' | sudo tee /home/nas-agent/.config/nas/mode" Enter
sleep 1

# Set up systemd service for daemon (optional, can start on-demand)
# ... (systemd unit file creation)

# Verify
tmux send-keys -t nas-setup "which nmux nmuxd" Enter
sleep 1
tmux capture-pane -t nas-setup -p
```

### For Sodo Mode

```bash
# Build and install nmux binary
# ... (similar to relay, but only nmux, not nmuxd)

# Configure sudoers
tmux send-keys -t nas-setup "sudo visudo -c -f /etc/sudoers.d/nas-sodo" Enter
# Explain: "visudo will check syntax. Add this rule:"
# nas-agent ALL=(human-user) NOPASSWD: /usr/local/bin/nmux-verify

# Create verification script
# ... (script that reads /dev/shm/nmux-* and validates token)

# Set mode
tmux send-keys -t nas-setup "echo 'sodo' | sudo tee /home/nas-agent/.config/nas/mode" Enter
```

## Phase 6: Generate Runtime Skill

Based on the chosen mode, edit `/nas-elevate/SKILL.md`:

```bash
# Update the MODE_MARKER section
MODE="direct"  # or relay/sodo

# Find the line between MODE_MARKER_START and MODE_MARKER_END
# Replace with mode-specific instructions
```

**For direct mode:**
```markdown
<!-- MODE_MARKER_START -->
**Current installation mode: direct**

No token required. Use tmux directly:
- Human creates session: `tmux new -s work`
- Human switches user: `su - <username>`
- Agent sends commands: `tmux send-keys -t work "command" Enter`
- Agent reads output: `tmux capture-pane -t work -p`
<!-- MODE_MARKER_END -->
```

**For relay/sodo modes:**
```markdown
<!-- MODE_MARKER_START -->
**Current installation mode: relay**

Token-based access. Use nmux:
- Human creates session: `nmux create work`
- Human copies token to agent
- Agent attaches: `echo "$TOKEN" | nmux attach work --token -`
- Agent sends: `nmux send work "command"`
- Agent reads: `nmux read work`
<!-- MODE_MARKER_END -->
```

Install the skill:

```bash
# Copy to Claude's skills directory (adjust path as needed)
tmux send-keys -t nas-setup "sudo -u nas-agent mkdir -p /home/nas-agent/.claude/skills" Enter
sleep 1

tmux send-keys -t nas-setup "sudo cp -r ./skills/nas-elevate /home/nas-agent/.claude/skills/" Enter
sleep 1

# Or package and install if using .skill format
# ... (use skill packaging process)
```

## Phase 7: Test the Installation

Guide the user through a test:

> "Let's verify everything works. I'll request elevation to run a simple test command.
>
> When I ask for elevation, please follow the instructions I give you—this confirms the system is set up correctly."

Then, trigger your own `/nas-elevate` skill (or walk through the process manually if testing during setup):

```bash
# Test command: check current user privileges
# In the elevated session, run: whoami
# Should show the human's username, not nas-agent
```

If the test succeeds:

> ✅ **Installation Complete!**
>
> The not-another-sandbox system is now installed in **{mode}** mode.
>
> **Next steps:**
> 1. Close this setup session: `tmux kill-session -t nas-setup`
> 2. In future, when an agent needs elevation, use `/nas-elevate`
> 3. Always monitor commands in real-time—close tmux if anything looks wrong
>
> **⚠️ Important reminder:** Check for orphan tmux sessions regularly with `tmux ls`

## Phase 8: Cleanup and Handoff

```bash
# Close setup session
tmux send-keys -t nas-setup "exit" Enter
sleep 1
tmux send-keys -t nas-setup "exit" Enter  # Exit su if used
sleep 1
```

Tell the user:

> "Setup is complete. You can now close the tmux session:
> ```
> tmux kill-session -t nas-setup
> ```
>
> To verify no orphans remain: `tmux ls`
>
> Documentation is in `./docs/design.md` and the `/nas-elevate` skill is ready to use."

## Troubleshooting Common Setup Issues

### "tmux not found"

```bash
tmux send-keys -t nas-setup "sudo apt update && sudo apt install -y tmux" Enter
```

### "useradd: user nas-agent already exists"

Agent account already exists. Skip creation, verify with `id nas-agent`.

### "go: command not found" (relay/sodo)

```bash
tmux send-keys -t nas-setup "sudo apt install -y golang" Enter
# Or use binary releases if available
```

### "Permission denied" on skill installation

Ensure using `sudo -u nas-agent` to write to agent's home directory.

### Build fails (relay/sodo)

Check build output for specific errors. Common issues:
- Missing dependencies (install build-essential)
- Network issues (git clone failed)
- Disk space

## Advanced: Migrating Between Modes

If the user later wants to switch modes (e.g., direct → relay):

1. Keep agent account
2. Install new mode's components (nmux binary, configs)
3. Update `/nas-elevate` MODE_MARKER section
4. Test with elevation request
5. Remove old mode's components if desired (optional)

## Security Checklist

Before finishing setup, confirm:

- [ ] Agent account exists and is separate from human account
- [ ] `/nas-elevate` skill is installed and mode-specific instructions are correct
- [ ] (relay/sodo) nmux binary is installed and executable
- [ ] (sodo) sudoers rule is syntactically correct
- [ ] (WSL) If hardening was requested, it's applied
- [ ] Test elevation succeeded
- [ ] User understands how to monitor sessions and close them
- [ ] Setup tmux session is closed

Tell the user:

> "Security checklist complete. All components are installed and tested."
