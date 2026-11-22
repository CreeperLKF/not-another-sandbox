package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"

	"github.com/spf13/cobra"
)

var (
	tokenFlag string
	rootCmd   = &cobra.Command{
		Use:   "nmux",
		Short: "not-another-sandbox session manager",
		Long:  "Manages privilege elevation sessions with token-based access control",
	}

	createCmd = &cobra.Command{
		Use:   "create <session-name>",
		Short: "Create a new elevated session",
		Args:  cobra.ExactArgs(1),
		RunE:  runCreate,
	}

	attachCmd = &cobra.Command{
		Use:   "attach <session-name>",
		Short: "Attach to a session with token",
		Args:  cobra.ExactArgs(1),
		RunE:  runAttach,
	}

	sendCmd = &cobra.Command{
		Use:   "send <session-name> <command>",
		Short: "Send command to session",
		Args:  cobra.MinimumNArgs(2),
		RunE:  runSend,
	}

	readCmd = &cobra.Command{
		Use:   "read <session-name>",
		Short: "Read session output",
		Args:  cobra.ExactArgs(1),
		RunE:  runRead,
	}

	listCmd = &cobra.Command{
		Use:   "list",
		Short: "List active sessions",
		RunE:  runList,
	}
)

func init() {
	attachCmd.Flags().StringVar(&tokenFlag, "token", "", "Session token (use '-' for stdin)")
	sendCmd.Flags().StringVar(&tokenFlag, "token", "", "Session token (use '-' for stdin)")
	readCmd.Flags().StringVar(&tokenFlag, "token", "", "Session token (use '-' for stdin)")

	rootCmd.AddCommand(createCmd, attachCmd, sendCmd, readCmd, listCmd)
}

func runCreate(cmd *cobra.Command, args []string) error {
	sessionName := args[0]

	// Generate token
	token, err := generateToken()
	if err != nil {
		return fmt.Errorf("failed to generate token: %w", err)
	}

	// Create tmux session
	tmuxCmd := exec.Command("tmux", "new-session", "-d", "-s", sessionName)
	if err := tmuxCmd.Run(); err != nil {
		return fmt.Errorf("failed to create tmux session: %w", err)
	}

	// Switch to target user
	humanUser := os.Getenv("NAS_HUMAN_USER")
	if humanUser == "" {
		humanUser = detectHumanUser()
	}

	switchCmd := exec.Command("tmux", "send-keys", "-t", sessionName, fmt.Sprintf("su - %s", humanUser), "Enter")
	if err := switchCmd.Run(); err != nil {
		return fmt.Errorf("failed to switch user: %w", err)
	}

	// Store token
	if err := storeToken(sessionName, token); err != nil {
		return fmt.Errorf("failed to store token: %w", err)
	}

	fmt.Printf("Session created: %s\n", sessionName)
	fmt.Printf("Token: %s\n", token)
	fmt.Println("\nShare this token with the agent to grant access.")

	return nil
}

func runAttach(cmd *cobra.Command, args []string) error {
	sessionName := args[0]
	token := tokenFlag

	// Read token from stdin if "-"
	if token == "-" {
		scanner := bufio.NewScanner(os.Stdin)
		if scanner.Scan() {
			token = strings.TrimSpace(scanner.Text())
		}
		if err := scanner.Err(); err != nil {
			return fmt.Errorf("failed to read token: %w", err)
		}
	}

	if token == "" {
		return fmt.Errorf("token required (use --token or pipe via stdin)")
	}

	// Verify token
	if err := verifyToken(sessionName, token); err != nil {
		return fmt.Errorf("authentication failed: %w", err)
	}

	fmt.Printf("Attached to session: %s\n", sessionName)
	return nil
}

func runSend(cmd *cobra.Command, args []string) error {
	sessionName := args[0]
	command := strings.Join(args[1:], " ")
	token := tokenFlag

	if token == "-" {
		scanner := bufio.NewScanner(os.Stdin)
		if scanner.Scan() {
			token = strings.TrimSpace(scanner.Text())
		}
	}

	if token == "" {
		return fmt.Errorf("token required")
	}

	if err := verifyToken(sessionName, token); err != nil {
		return fmt.Errorf("authentication failed: %w", err)
	}

	// Send command via tmux
	tmuxCmd := exec.Command("tmux", "send-keys", "-t", sessionName, command, "Enter")
	if err := tmuxCmd.Run(); err != nil {
		return fmt.Errorf("failed to send command: %w", err)
	}

	return nil
}

func runRead(cmd *cobra.Command, args []string) error {
	sessionName := args[0]
	token := tokenFlag

	if token == "-" {
		scanner := bufio.NewScanner(os.Stdin)
		if scanner.Scan() {
			token = strings.TrimSpace(scanner.Text())
		}
	}

	if token == "" {
		return fmt.Errorf("token required")
	}

	if err := verifyToken(sessionName, token); err != nil {
		return fmt.Errorf("authentication failed: %w", err)
	}

	// Capture pane
	tmuxCmd := exec.Command("tmux", "capture-pane", "-t", sessionName, "-p")
	output, err := tmuxCmd.Output()
	if err != nil {
		return fmt.Errorf("failed to capture pane: %w", err)
	}

	fmt.Print(string(output))
	return nil
}

func runList(cmd *cobra.Command, args []string) error {
	tmuxCmd := exec.Command("tmux", "list-sessions")
	output, err := tmuxCmd.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {
			fmt.Println("No active sessions")
			return nil
		}
		return fmt.Errorf("failed to list sessions: %w", err)
	}

	fmt.Print(string(output))
	return nil
}

// Token management

func generateToken() (string, error) {
	// Generate random token
	randBytes := make([]byte, 16)
	if _, err := io.ReadFull(os.Stdin, randBytes); err != nil {
		// Fallback to simple generation
		return fmt.Sprintf("%x", os.Getpid()), nil
	}
	return fmt.Sprintf("%x", randBytes), nil
}

func storeToken(session, token string) error {
	tokenFile := fmt.Sprintf("/dev/shm/nmux-%s", session)
	f, err := os.OpenFile(tokenFile, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	defer f.Close()

	_, err = f.WriteString(token)
	return err
}

func verifyToken(session, token string) error {
	tokenFile := fmt.Sprintf("/dev/shm/nmux-%s", session)
	data, err := os.ReadFile(tokenFile)
	if err != nil {
		return fmt.Errorf("session not found or token expired")
	}

	storedToken := strings.TrimSpace(string(data))
	if storedToken != token {
		return fmt.Errorf("invalid token")
	}

	return nil
}

func detectHumanUser() string {
	// Try to detect from UID 1000
	if user := os.Getenv("SUDO_USER"); user != "" {
		return user
	}
	// Fallback
	return "ubuntu"
}

func main() {
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}
