package main

import (
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"

	"github.com/spf13/cobra"
)

var (
	socketPath string
	rootCmd    = &cobra.Command{
		Use:   "nmuxd",
		Short: "not-another-sandbox daemon",
		Long:  "Background daemon for relay mode token authentication",
		RunE:  runDaemon,
	}
)

func init() {
	rootCmd.Flags().StringVar(&socketPath, "socket", "/run/nmuxd.sock", "Unix socket path")
}

func runDaemon(cmd *cobra.Command, args []string) error {
	// Remove old socket
	os.Remove(socketPath)

	// Create Unix socket
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return fmt.Errorf("failed to create socket: %w", err)
	}
	defer listener.Close()

	// Set socket permissions
	if err := os.Chmod(socketPath, 0660); err != nil {
		return fmt.Errorf("failed to set socket permissions: %w", err)
	}

	log.Printf("nmuxd started on %s", socketPath)

	// Handle signals
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-sigChan
		log.Println("Shutting down...")
		listener.Close()
		os.Exit(0)
	}()

	// Accept connections
	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Printf("Accept error: %v", err)
			continue
		}

		go handleConnection(conn)
	}
}

func handleConnection(conn net.Conn) {
	defer conn.Close()

	// Get peer credentials
	ucred, err := getPeerCred(conn)
	if err != nil {
		log.Printf("Failed to get peer credentials: %v", err)
		return
	}

	log.Printf("Connection from UID %d, GID %d", ucred.Uid, ucred.Gid)

	// Handle commands
	// (command protocol implementation here)
}

func getPeerCred(conn net.Conn) (*syscall.Ucred, error) {
	unixConn, ok := conn.(*net.UnixConn)
	if !ok {
		return nil, fmt.Errorf("not a unix connection")
	}

	f, err := unixConn.File()
	if err != nil {
		return nil, err
	}
	defer f.Close()

	ucred, err := syscall.GetsockoptUcred(int(f.Fd()), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
	if err != nil {
		return nil, err
	}

	return ucred, nil
}

func main() {
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}
