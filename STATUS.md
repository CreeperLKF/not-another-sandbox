# Development Status

## ✅ Completed Components

### Documentation
- [x] Complete design document (`docs/design.md`)
- [x] README with quick start guide
- [x] Architecture overview with three modes
- [x] Security model and threat analysis

### Skills
- [x] `nas-elevate` - Runtime privilege elevation skill
  - Mode detection
  - Human guidance for session creation
  - Token exchange handling
  - Safety warnings and cleanup reminders
- [x] `nas-setup-guide` - Installation guide skill
  - Environment detection
  - Mode recommendations
  - WSL vulnerability detection
  - Interactive setup flow

### Implementation
- [x] Interactive install script (`install.sh`)
  - Mode selection with recommendations
  - Account creation
  - WSL vulnerability detection
  - Mode-specific installation
  - Skill generation
- [x] Direct mode (pure shell)
  - Zero dependencies beyond bash + tmux
  - No binaries, no tokens
- [x] Sodo mode (shell + sudoers)
  - `scripts/nmux-sodo.sh` - Token wrapper
  - `scripts/nmux-verify.sh` - Sudo verification
  - Zero Go dependencies
- [x] Relay mode (Go binaries)
  - `relay/cmd/nmux/` - CLI with crypto/rand tokens
  - `relay/cmd/nmuxd/` - Minimal daemon
  - Only built when relay mode selected
- [x] Build system (Makefile for relay only)

## 🚧 Known Limitations

### Relay Mode Daemon Protocol
`nmuxd` connection handling is minimal. For production:
- Binary protocol definition (session ID, token, command, response)
- Session state management
- Multiple concurrent client support
- Graceful shutdown with session preservation

### Token Expiration
Current tokens never expire. Consider:
- Timestamp-based expiration
- Explicit revoke command
- Auto-cleanup on tmux session close

### Sodo Mode Token Passing
`nmux-sodo.sh` uses environment variable `$NAS_TOKEN` for send/read.
Better approach: pass via stdin on each call

### Testing
No test coverage yet. Needs:
- Unit tests for token management
- Integration tests for session lifecycle
- TUI interaction tests
- Skills evaluation (via skill-creator)

## 📋 TODO for Production

### High Priority
- [ ] Secure token generation with crypto/rand
- [ ] Complete daemon protocol implementation
- [ ] Finish setup installation sequences
- [ ] Add systemd service files for nmuxd
- [ ] Implement token cleanup on session close

### Medium Priority
- [ ] Add logging framework
- [ ] Implement configuration file support
- [ ] Create migration scripts between modes
- [ ] Add shell completion scripts
- [ ] Write troubleshooting guide

### Low Priority
- [ ] WSL /init patching automation
- [ ] Web-based session monitoring TUI
- [ ] Multi-user session sharing
- [ ] Session recording/audit logs

## 🧪 Testing Plan

1. **Direct mode smoke test**
   - Create agent account
   - Create tmux session
   - Send commands via tmux send-keys
   - Verify output capture

2. **Relay mode functional test**
   - Start nmuxd daemon
   - Create session with token
   - Attach from agent account
   - Send/read commands
   - Verify isolation

3. **Skills evaluation**
   - Use skill-creator to test nas-elevate
   - Create eval scenarios (package install, config change, service restart)
   - Measure token handling correctness
   - Check safety warning effectiveness

## 🔒 Security Review Checklist

- [x] Token passed via stdin (not argv)
- [x] Token files in /dev/shm with 0600
- [ ] Verify no token leakage in logs
- [ ] Audit tmux socket permissions
- [ ] Test SO_PEERCRED enforcement
- [ ] Verify session isolation in multi-agent scenarios

## 📝 Notes

### Design Decisions
- **No single revoke command**: Closing tmux = revoking access. Keeps it simple.
- **Skills not self-modifying**: Setup edits skill files, but skills themselves are read-only at runtime.
- **WSL hardening optional**: User can skip if single-agent trusted environment.
- **Dependency minimization**: 90% of users (direct/sodo) need zero compilation. Only relay mode requires Go.
- **Token generation**: System resources (uuidgen, /proc/sys/kernel/random/uuid) for sodo/direct, crypto/rand for relay.

### Known Issues
- [ ] `relay/go.mod` needs `go mod tidy` before building
- [ ] Sodo mode token passing via env var (should use stdin)
- [ ] Install script assumes tmux session named "nas-setup" exists

### Future Enhancements
- Consider abstract Unix sockets for daemon (no filesystem cleanup)
- Add JSON output mode for programmatic usage
- Support session templates (pre-configured environments)
