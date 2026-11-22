---
name: nas-elevate
description: Request privilege elevation through supervised tmux sessions. Use this when you need elevated permissions to install packages, modify system configuration, access protected files, or perform any operation requiring higher privileges than your current agent account provides. Also use when the user mentions sudo, root access, system administration, or asks you to do something that requires permissions you don't have.
---

# Privilege Elevation via Supervised Sessions

This skill guides you through requesting temporary elevated privileges under human supervision using the not-another-sandbox (NAS) system.

## Core Principles

**Before requesting elevation:**
- Only request when genuinely necessary for the task
- Clearly explain to the human *why* you need elevation and *what* you'll do with it
- Be specific about which commands you intend to run
- Never assume elevation is granted automatically

**During elevation:**
- The human can see every command you send in real-time
- Run only the commands you explained beforehand
- If the human closes the session, respect that decision immediately

**After completion:**
- Confirm when you're done so the human can close the session
- Never leave tmux sessions running after you finish

## Step 1: Detect Installation Mode

Check which mode is installed:

```bash
# Check for nmux binary
which nmux 2>/dev/null

# Check for NAS config
cat ~/.config/nas/mode 2>/dev/null || echo "direct"
```

Based on the result:
- If `nmux` exists and config shows "relay" or "sodo" → **Token-based mode** (relay/sodo)
- Otherwise → **Direct mode**

<!-- MODE_MARKER_START -->
**Current installation mode: UNINITIALIZED**

This section will be updated by the setup process.
<!-- MODE_MARKER_END -->

## Step 2: Explain Your Need

Before requesting elevation, tell the human:

1. **What you need to do** (be specific)
2. **Why it requires elevation** (which operations need higher privileges)
3. **Which commands you'll run** (give examples)

Example:
> "I need elevated privileges to install the `build-essential` package and configure ufw firewall rules. This requires running:
> - `apt update && apt install -y build-essential`
> - `ufw allow 8080/tcp`
> - `ufw enable`
> 
> Could you create an elevated session for me?"

## Step 3: Request Session Creation

### For Direct Mode

Guide the human to create a tmux session in the agent account and switch to their own user:

```
Please run these commands:
1. tmux new -s work
2. Inside the tmux, run: su - <your-username>
3. Return here and confirm when ready
```

Once confirmed, you can send commands:

```bash
# Send a command
tmux send-keys -t work "apt update" Enter

# Read the output
tmux capture-pane -t work -p
```

### For Token-Based Mode (relay/sodo)

Guide the human to create an authorized session:

```
Please run: nmux create work

This will output a session token. Copy the token and paste it back here.
```

Once you receive the token:

```bash
# Attach to the session (token from stdin to avoid process list exposure)
echo "TOKEN_HERE" | nmux attach work --token -

# Send commands
nmux send work "apt update"

# Read output
nmux read work
```

## Step 4: Execute Your Work

**Safety reminders:**
- Run only the commands you explained in Step 2
- If you encounter unexpected situations, explain them to the human before proceeding
- Read output after each command to verify success
- If the human types something in the session, you'll see it in the output—respect their intervention

**Pattern for each command:**
1. Send the command
2. Wait briefly (1-2 seconds for quick commands, longer for apt/compilation)
3. Read the output
4. Check for errors
5. Explain the result to the human

Example sequence:

```bash
# Send command
tmux send-keys -t work "apt update" Enter

# Wait
sleep 2

# Check result
OUTPUT=$(tmux capture-pane -t work -p)
echo "$OUTPUT"

# Next command only if previous succeeded
if echo "$OUTPUT" | grep -q "Reading package lists... Done"; then
    tmux send-keys -t work "apt install -y build-essential" Enter
fi
```

## Step 5: Clean Exit

When you finish:

1. Tell the human you're done:
   > "I've completed the installation. You can now close the tmux session with: `tmux kill-session -t work`"

2. In direct mode, the human should also check for orphaned sessions:
   ```bash
   tmux ls
   ```

3. Never leave sessions running—they remain elevated and accessible to other processes

## Safety Warnings

⚠️ **For the human:**
- Watch the commands being executed in real-time
- If you see unexpected or suspicious commands, close the tmux immediately: `tmux kill-session -t work`
- After the agent finishes, verify no orphan sessions remain: `tmux ls`
- In direct mode, any agent with the same UID can attach to the session—close it promptly

⚠️ **For the agent:**
- Elevated sessions have full access to the user's privileges
- A mistake here can damage the system
- If unsure about a command's safety, ask the human first
- Never run commands you didn't explain in Step 2

## Troubleshooting

**Session not found:**
```bash
tmux ls  # List all sessions
```
The human may have named it differently or it may have been closed.

**Permission denied when attaching (token mode):**
- Verify the token was copied correctly (no extra spaces/newlines)
- Check if the session still exists: `nmux list` or `tmux ls`
- The token may have been revoked—ask the human to create a new session

**Commands not executing:**
- Check if the prompt is ready: `tmux capture-pane -t work -p | tail -n 3`
- You might be sending commands while the previous one is still running
- Wait longer between send and capture

**Output looks garbled:**
- Terminal control codes can make output hard to parse
- Use `tmux capture-pane -t work -p -e` to strip escape codes
- For structured data, redirect to a file instead of reading the screen

## Example: Complete Workflow

```bash
# 1. Check mode
MODE=$(cat ~/.config/nas/mode 2>/dev/null || echo "direct")

# 2. Explain to human (in your response to them)
# "I need to install nginx and start it. This requires:
#  - apt update && apt install -y nginx
#  - systemctl start nginx
#  May I request an elevated session?"

# 3. After human creates session (direct mode example)
tmux send-keys -t work "apt update" Enter
sleep 3
tmux capture-pane -t work -p

tmux send-keys -t work "apt install -y nginx" Enter
sleep 10
tmux capture-pane -t work -p

tmux send-keys -t work "systemctl start nginx" Enter
sleep 2
tmux capture-pane -t work -p

# 4. Verify
tmux send-keys -t work "systemctl status nginx" Enter
sleep 1
tmux capture-pane -t work -p

# 5. Tell human you're done
# "Installation complete. You can close the session: tmux kill-session -t work"
```

## Token Security (relay/sodo modes)

**Never:**
- Put tokens in command-line arguments (visible in `ps aux`)
- Write tokens to disk (except via stdin redirection to a pipe)
- Log tokens in your output to the human
- Share tokens between unrelated agents without human approval

**Always:**
- Pass tokens via stdin: `echo "$TOKEN" | nmux attach work --token -`
- Treat tokens as secrets
- If a token leaks (e.g., in logs), ask the human to revoke and create a new session

## Multi-Agent Scenarios

If you spawn subagents that also need elevation:
- **Direct mode**: They can attach to the same tmux session (no isolation)
- **Token mode**: Share your token with trusted subagents, or ask the human for separate tokens for each

Remember: In token modes, the human issued the token to *you*. If you pass it to subagents, you're vouching for their behavior.
