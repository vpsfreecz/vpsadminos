// Run a container within a PTY and forward its input/output via UNIX socket.
//
// Usage: $0 <title> <socket> lxc-start...
//
// `socket` is a path where a UNIX server socket will be created. This wrapper
// accepts one client on the UNIX server, accepts commands and forwards data
// to/from the wrapped process.
//
// Data read from the client are expected to be in JSON, one command on every
// line.
//
//   {
//     "keys": base64 encoded input data,
//     "rows": terminal height,
//     "cols": terminal width
//   }
//
// The command can contain just `keys`, `rows` and `cols` together, or all three
// keys.
//
// Data sent to the client are in a raw form, just as the wrapped process writes
// them.

package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"github.com/creack/pty"
	"github.com/erikdubbelboer/gspt"
	"golang.org/x/sys/unix"
	"log"
	"net"
	"os"
	"os/exec"
)

type command struct {
	Keys string
	Rows uint16
	Cols uint16
}

func main() {
	gspt.SetProcTitle(fmt.Sprintf("osctld: CT %s", os.Args[1]))

	server, err := net.Listen("unix", os.Args[2])
	if err != nil {
		log.Fatal("listen error:", err)
	}
	defer server.Close()

	cmd := exec.Command(os.Args[3], os.Args[4:]...)

	prog, err := pty.Start(cmd)
	if err != nil {
		log.Fatal("unable to exec", err)
	}

	clientAcceptChan := make(chan net.Conn, 1)
	clientConnChan := make(chan net.Conn, 1)
	clientCloseChan := make(chan net.Conn, 1)
	clientWriteChan := make(chan []byte, 16)
	go clientWriter(clientConnChan, clientCloseChan, clientWriteChan)

	progWriteChan := make(chan *command, 16)
	go progWriter(prog, progWriteChan)

	go serverRoutine(server, clientAcceptChan)
	go clientManager(clientAcceptChan, clientCloseChan, clientConnChan, progWriteChan)

	data := make([]byte, 4096)

	for {
		n, err := prog.Read(data)
		if err != nil {
			log.Print("error reading from program, exiting", err)
			break
		}

		//log.Print("read from program", data[0:n])
		clientWriteChan <- data[0:n]
	}

	server.Close()

	log.Print("killing the program")
	cmd.Process.Kill()

	log.Print("waiting for program to exit")
	cmd.Wait()
}

func serverRoutine(server net.Listener, clientAcceptChan chan<- net.Conn) {
	for {
		conn, err := server.Accept()
		if err != nil {
			log.Print("accept error:", err)
			return
		}

		log.Print("client connected")

		creds, err := readCreds(conn)
		if err != nil {
			log.Print("failed to read creds")
			conn.Close()
			continue
		}

		if creds.Uid != 0 {
			log.Printf("client has uid %d, accepting only 0", creds.Uid)
			conn.Close()
			continue
		}

		clientAcceptChan <- conn
	}
}

func clientManager(acceptChan <-chan net.Conn, closeChan chan net.Conn, clientChan chan<- net.Conn, progWriteChan chan<- *command) {
	hasClient := false

	for {
		select {
		case conn := <-acceptChan:
			if hasClient {
				log.Print("client already connected")
				conn.Close()
			} else {
				log.Print("accepted new client")
				hasClient = true
				clientChan <- conn
				go clientReader(conn, closeChan, progWriteChan)
			}
		case conn := <-closeChan:
			hasClient = false
			conn.Close()
		}
	}
}

func clientReader(conn net.Conn, closeChan chan<- net.Conn, progWriteChan chan<- *command) {
	scanner := bufio.NewScanner(conn)
	scanner.Split(bufio.ScanLines)

	for scanner.Scan() {
		cmd := command{
			Rows: 0,
			Cols: 0,
		}

		if err := json.Unmarshal(scanner.Bytes(), &cmd); err != nil {
			log.Print("ignoring invalid command", err)
			continue
		}

		progWriteChan <- &cmd
	}

	closeChan <- conn
}

func clientWriter(connChan <-chan net.Conn, closeChan chan<- net.Conn, writeChan <-chan []byte) {
	var client net.Conn
	var buffer bytes.Buffer

	for {
		select {
		case conn := <-connChan:
			client = conn

			if buffer.Len() > 0 {
				//log.Print("dumping buffer to client")

				if _, err := client.Write(buffer.Bytes()); err != nil {
					closeChan <- client
					client = nil
				}
			}
		case data := <-writeChan:
			if client == nil {
				//log.Print("writing to buffer")

				if (buffer.Len() + len(data)) > 32_768 {
					//log.Print("resetting buffer")
					buffer.Reset()
				}

				buffer.Write(data)
			} else {
				//log.Print("writing to client")

				if _, err := client.Write(data); err != nil {
					closeChan <- client
					client = nil
				}
			}
		}
	}
}

func progWriter(prog *os.File, writeChan <-chan *command) {
	for {
		cmd := <-writeChan

		if cmd.Keys != "" {
			decoded, err := base64.StdEncoding.DecodeString(cmd.Keys)
			if err != nil {
				log.Print("error decoding keys", err)
			}

			//log.Print("writing to program", decoded)

			if _, err := prog.Write(decoded); err != nil {
				log.Print("error while writing to program", err)
				prog.Close()
				return
			}
		}

		if cmd.Rows > 0 && cmd.Cols > 0 {
			newSize := pty.Winsize{
				Rows: cmd.Rows,
				Cols: cmd.Cols,
			}
			if err := pty.Setsize(prog, &newSize); err != nil {
				log.Print("error resizing pty", err)
			}
		}
	}
}

func readCreds(conn net.Conn) (*unix.Ucred, error) {
	var cred *unix.Ucred

	uc, ok := conn.(*net.UnixConn)
	if !ok {
		return nil, fmt.Errorf("unexpected socket type")
	}

	raw, err := uc.SyscallConn()
	if err != nil {
		return nil, fmt.Errorf("error opening raw connection: %s", err)
	}

	err2 := raw.Control(func(fd uintptr) {
		cred, err = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
	})

	if err != nil {
		return nil, fmt.Errorf("GetsockoptUcred() error: %s", err)
	}

	if err2 != nil {
		return nil, fmt.Errorf("Control() error: %s", err2)
	}

	return cred, nil
}
