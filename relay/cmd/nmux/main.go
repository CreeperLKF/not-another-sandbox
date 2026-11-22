package main

import (
	"bufio"
	"crypto/rand"
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
		Short: "Session manager for relay mode",
	}
	createCmd = &cobra.Command{Use: "create <session>", Args: cobra.ExactArgs(1), RunE: runCreate}
	attachCmd = &cobra.Command{Use: "attach <session>", Args: cobra.ExactArgs(1), RunE: runAttach}
	sendCmd   = &cobra.Command{Use: "send <session> <cmd>", Args: cobra.MinimumNArgs(2), RunE: runSend}
	readCmd   = &cobra.Command{Use: "read <session>", Args: cobra.ExactArgs(1), RunE: runRead}
	listCmd   = &cobra.Command{Use: "list", RunE: runList}
)

func init() {
	attachCmd.Flags().StringVar(&tokenFlag, "token", "", "Token (use '-' for stdin)")
	sendCmd.Flags().StringVar(&tokenFlag, "token", "", "Token (use '-' for stdin)")
	readCmd.Flags().StringVar(&tokenFlag, "token", "", "Token (use '-' for stdin)")
	rootCmd.AddCommand(createCmd, attachCmd, sendCmd, readCmd, listCmd)
}

func runCreate(cmd *cobra.Command, args []string) error {
	session := args[0]
	token := generateToken()
	if err := exec.Command("tmux", "new-session", "-d", "-s", session).Run(); err != nil {
		return err
	}
	humanUser := os.Getenv("NAS_HUMAN_USER")
	if humanUser == "" {
		humanUser = "ubuntu"
	}
	exec.Command("tmux", "send-keys", "-t", session, "su - "+humanUser, "Enter").Run()
	os.WriteFile("/dev/shm/nmux-"+session, []byte(token), 0600)
	fmt.Printf("Session: %s\nToken: %s\n", session, token)
	return nil
}

func runAttach(cmd *cobra.Command, args []string) error {
	token := readToken()
	if err := verifyToken(args[0], token); err != nil {
		return err
	}
	fmt.Println("Attached to", args[0])
	return nil
}

func runSend(cmd *cobra.Command, args []string) error {
	token := readToken()
	if err := verifyToken(args[0], token); err != nil {
		return err
	}
	return exec.Command("tmux", "send-keys", "-t", args[0], strings.Join(args[1:], " "), "Enter").Run()
}

func runRead(cmd *cobra.Command, args []string) error {
	token := readToken()
	if err := verifyToken(args[0], token); err != nil {
		return err
	}
	out, _ := exec.Command("tmux", "capture-pane", "-t", args[0], "-p").Output()
	fmt.Print(string(out))
	return nil
}

func runList(cmd *cobra.Command, args []string) error {
	out, _ := exec.Command("tmux", "list-sessions").Output()
	fmt.Print(string(out))
	return nil
}

func readToken() string {
	if tokenFlag == "-" {
		s := bufio.NewScanner(os.Stdin)
		s.Scan()
		return strings.TrimSpace(s.Text())
	}
	return tokenFlag
}

func generateToken() string {
	b := make([]byte, 16)
	io.ReadFull(rand.Reader, b)
	return fmt.Sprintf("%x", b)
}

func verifyToken(session, token string) error {
	data, err := os.ReadFile("/dev/shm/nmux-" + session)
	if err != nil || strings.TrimSpace(string(data)) != token {
		return fmt.Errorf("invalid token")
	}
	return nil
}

func main() { rootCmd.Execute() }
