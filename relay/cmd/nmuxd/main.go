package main

import (
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	socketPath := "/run/nmuxd.sock"
	os.Remove(socketPath)
	
	l, err := net.Listen("unix", socketPath)
	if err != nil {
		log.Fatal(err)
	}
	defer l.Close()
	
	os.Chmod(socketPath, 0660)
	log.Println("nmuxd listening on", socketPath)
	
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sig
		l.Close()
		os.Exit(0)
	}()
	
	for {
		conn, err := l.Accept()
		if err != nil {
			continue
		}
		go handleConn(conn)
	}
}

func handleConn(c net.Conn) {
	defer c.Close()
	fmt.Fprintf(c, "nmuxd placeholder\n")
}
