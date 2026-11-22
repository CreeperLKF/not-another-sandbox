package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// Installation modes
const (
	ModeDirect = "direct"
	ModeRelay  = "relay"
	ModeSodo   = "sodo"
)

// Setup steps
const (
	StepWelcome = iota
	StepMode
	StepAccount
	StepWSL
	StepElevated
	StepInstalling
	StepComplete
)

type model struct {
	step              int
	mode              string
	agentAccount      string
	createNewAccount  bool
	humanAccount      string
	wslDetected       bool
	wslVulnerable     bool
	patchWSL          bool
	addPromptWarning  bool
	tmuxReady         bool
	installProgress   []string
	err               error
	width             int
	height            int
}

var (
	titleStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("205")).
			MarginBottom(1)

	normalStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("252"))

	dimStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("241"))

	errorStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("196"))

	successStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("42"))

	highlightStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("226")).
			Bold(true)
)

func initialModel() model {
	// Detect environment
	wslDetected, wslVulnerable := detectWSL()
	humanAccount := detectHumanAccount()

	return model{
		step:          StepWelcome,
		mode:          ModeDirect,
		humanAccount:  humanAccount,
		wslDetected:   wslDetected,
		wslVulnerable: wslVulnerable,
	}
}

func (m model) Init() tea.Cmd {
	return nil
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil

	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "q":
			if m.step == StepComplete || m.step == StepWelcome {
				return m, tea.Quit
			}

		case "enter":
			return m.handleEnter()

		case "1", "2", "3":
			if m.step == StepMode {
				switch msg.String() {
				case "1":
					m.mode = ModeDirect
				case "2":
					m.mode = ModeRelay
				case "3":
					m.mode = ModeSodo
				}
			}

		case "y", "n":
			return m.handleYesNo(msg.String() == "y")
		}
	}

	return m, nil
}

func (m model) handleEnter() (tea.Model, tea.Cmd) {
	switch m.step {
	case StepWelcome:
		m.step = StepMode
	case StepMode:
		m.step = StepAccount
	case StepAccount:
		m.step = StepWSL
	case StepWSL:
		if m.wslDetected && m.wslVulnerable {
			// Already handled via y/n
		} else {
			m.step = StepElevated
		}
	case StepElevated:
		if m.tmuxReady {
			m.step = StepInstalling
			return m, m.startInstallation()
		}
	case StepComplete:
		return m, tea.Quit
	}
	return m, nil
}

func (m model) handleYesNo(yes bool) (tea.Model, tea.Cmd) {
	switch m.step {
	case StepAccount:
		m.createNewAccount = yes
		m.step = StepWSL
		return m, nil

	case StepWSL:
		if m.wslDetected && m.wslVulnerable {
			m.patchWSL = yes
			// Ask about prompt warning
			return m, nil
		}

	case StepElevated:
		if yes {
			m.tmuxReady = true
		}
		return m, nil
	}
	return m, nil
}

func (m model) startInstallation() tea.Cmd {
	return func() tea.Msg {
		// Execute installation commands via tmux
		m.installProgress = append(m.installProgress, "Starting installation...")

		// Create agent account if needed
		if m.createNewAccount {
			err := execTmux("nas-setup", fmt.Sprintf("id %s 2>/dev/null || sudo useradd -m -s /bin/bash %s", m.agentAccount, m.agentAccount))
			if err != nil {
				return errMsg{err}
			}
			m.installProgress = append(m.installProgress, fmt.Sprintf("✓ Created agent account: %s", m.agentAccount))
		}

		// Mode-specific installation
		switch m.mode {
		case ModeDirect:
			// No additional components needed
			m.installProgress = append(m.installProgress, "✓ Direct mode: no additional components")

		case ModeRelay, ModeSodo:
			// Build binaries
			m.installProgress = append(m.installProgress, "Building nmux binaries...")
			// (build commands here)
		}

		// Generate skill
		m.installProgress = append(m.installProgress, "Generating /nas-elevate skill...")
		// (skill generation here)

		return installCompleteMsg{}
	}
}

type errMsg struct{ err error }
type installCompleteMsg struct{}

func (m model) View() string {
	switch m.step {
	case StepWelcome:
		return m.viewWelcome()
	case StepMode:
		return m.viewMode()
	case StepAccount:
		return m.viewAccount()
	case StepWSL:
		return m.viewWSL()
	case StepElevated:
		return m.viewElevated()
	case StepInstalling:
		return m.viewInstalling()
	case StepComplete:
		return m.viewComplete()
	}
	return ""
}

func (m model) viewWelcome() string {
	return titleStyle.Render("not-another-sandbox Setup") + "\n\n" +
		normalStyle.Render("Welcome! This will set up privilege delegation for AI agents\nunder human supervision.\n\n") +
		dimStyle.Render("Press [Enter] to continue, [Ctrl+C] to quit")
}

func (m model) viewMode() string {
	return titleStyle.Render("Step 1: Installation Mode") + "\n\n" +
		normalStyle.Render("Choose how agents will request elevation:\n\n") +
		"1. " + highlightStyle.Render("direct") + "  - Single agent, no tokens (default)\n" +
		"   " + dimStyle.Render("✓ Simplest, zero overhead") + "\n" +
		"   " + dimStyle.Render("✗ Any agent with same UID can attach\n\n") +
		"2. " + normalStyle.Render("relay") + "  - Multi-agent, daemon-based\n" +
		"   " + dimStyle.Render("✓ Strong isolation, token auth") + "\n" +
		"   " + dimStyle.Render("✗ Requires background daemon\n\n") +
		"3. " + normalStyle.Render("sodo") + "   - Multi-agent, sudoers-based\n" +
		"   " + dimStyle.Render("✓ No daemon, token auth") + "\n" +
		"   " + dimStyle.Render("✗ Slower, requires sudoers\n\n") +
		dimStyle.Render(fmt.Sprintf("Current selection: %s\n", m.mode)) +
		dimStyle.Render("Press [1-3] to select, [Enter] to confirm")
}

func (m model) viewAccount() string {
	return titleStyle.Render("Step 2: Agent Account") + "\n\n" +
		normalStyle.Render("Create a new account for agents?\n\n") +
		"Username: " + highlightStyle.Render(m.agentAccount) + "\n" +
		"Human account: " + highlightStyle.Render(m.humanAccount) + "\n\n" +
		dimStyle.Render("Press [y] to create new, [n] to use existing")
}

func (m model) viewWSL() string {
	s := titleStyle.Render("Step 3: WSL Hardening") + "\n\n"

	if !m.wslDetected {
		s += normalStyle.Render("WSL not detected. Skipping.\n\n")
		s += dimStyle.Render("Press [Enter] to continue")
		return s
	}

	if !m.wslVulnerable {
		s += successStyle.Render("✓ WSL interop is already hardened.\n\n")
		s += dimStyle.Render("Press [Enter] to continue")
		return s
	}

	s += errorStyle.Render("⚠ WSL Interop Vulnerability Detected\n\n")
	s += normalStyle.Render("Any user can execute wsl.exe -u root to gain root access.\n")
	s += normalStyle.Render("/run/WSL/*_interop sockets have 0777 permissions.\n\n")
	s += "Options:\n"
	s += "1. " + highlightStyle.Render("Patch /init") + " (recommended, requires compilation)\n"
	s += "2. " + normalStyle.Render("Add prompt warning") + " (quick, less secure)\n"
	s += "3. " + dimStyle.Render("Skip") + " (not recommended)\n\n"
	s += dimStyle.Render("Apply hardening? [y/n]")

	return s
}

func (m model) viewElevated() string {
	s := titleStyle.Render("Step 4: Elevated Setup") + "\n\n"
	s += normalStyle.Render("The next steps require sudo privileges.\n\n")
	s += highlightStyle.Render("This is your first tutorial:\n\n")
	s += "1. Open a new terminal\n"
	s += "2. Run: " + highlightStyle.Render("tmux new -s nas-setup") + "\n"
	s += "3. Inside tmux: " + highlightStyle.Render("sudo -v") + "\n"
	s += "4. Return here\n\n"
	s += normalStyle.Render("I'll send commands to that session. ") + errorStyle.Render("If you see anything\nunexpected, close tmux immediately") + normalStyle.Render(" with Ctrl+B, then :kill-session\n\n")

	if m.tmuxReady {
		s += successStyle.Render("✓ Ready to proceed\n\n")
		s += dimStyle.Render("Press [Enter] to start installation")
	} else {
		s += dimStyle.Render("Press [y] when ready, [n] to cancel")
	}

	return s
}

func (m model) viewInstalling() string {
	s := titleStyle.Render("Installing...") + "\n\n"
	for _, line := range m.installProgress {
		s += normalStyle.Render(line) + "\n"
	}
	return s
}

func (m model) viewComplete() string {
	s := titleStyle.Render("✓ Installation Complete!") + "\n\n"
	s += successStyle.Render(fmt.Sprintf("not-another-sandbox is installed in %s mode.\n\n", m.mode))
	s += normalStyle.Render("Next steps:\n")
	s += "1. Close the setup session: " + highlightStyle.Render("tmux kill-session -t nas-setup") + "\n"
	s += "2. When agents need elevation, use: " + highlightStyle.Render("/nas-elevate") + "\n"
	s += "3. Always monitor commands in real-time\n\n"
	s += errorStyle.Render("⚠ Important: ") + normalStyle.Render("Check for orphan tmux sessions: ") + highlightStyle.Render("tmux ls") + "\n\n"
	s += dimStyle.Render("Press [q] to quit")
	return s
}

// Helper functions

func detectWSL() (detected bool, vulnerable bool) {
	// Check /proc/version
	data, err := os.ReadFile("/proc/version")
	if err == nil && strings.Contains(strings.ToLower(string(data)), "microsoft") {
		detected = true
	}

	// Check /run/WSL directory
	if _, err := os.Stat("/run/WSL"); err == nil {
		detected = true
	}

	if !detected {
		return false, false
	}

	// Check interop socket permissions
	entries, err := os.ReadDir("/run/WSL")
	if err != nil {
		return detected, false
	}

	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), "_interop") {
			info, err := entry.Info()
			if err == nil && info.Mode().Perm() == 0777 {
				vulnerable = true
				break
			}
		}
	}

	return detected, vulnerable
}

func detectHumanAccount() string {
	if user := os.Getenv("USER"); user != "" {
		return user
	}
	if user := os.Getenv("LOGNAME"); user != "" {
		return user
	}
	return "unknown"
}

func execTmux(session, command string) error {
	cmd := exec.Command("tmux", "send-keys", "-t", session, command, "Enter")
	return cmd.Run()
}

func main() {
	p := tea.NewProgram(initialModel(), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Printf("Error: %v\n", err)
		os.Exit(1)
	}
}
