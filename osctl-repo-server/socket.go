package reposerver

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type ControlSocket struct {
	Path, Role, Repository string
	GID                    int
}
type ControlServer struct {
	listeners   []net.Listener
	mu          sync.Mutex
	connections map[net.Conn]bool
	wg          sync.WaitGroup
}

// ListenControl opens role-specific local sockets. Ownership comes from the
// filesystem, not any untrusted JSON role field. Never unlink a non-socket path.
func (s *Store) ListenControl(config []ControlSocket) (*ControlServer, error) {
	server := &ControlServer{connections: map[net.Conn]bool{}}
	for _, c := range config {
		if c.Path == "" || !component.MatchString(c.Repository) || !contains([]string{"producer", "publisher", "admin"}, c.Role) {
			server.Close()
			return nil, problem("invalid", "invalid control socket configuration")
		}
		if e := os.MkdirAll(filepath.Dir(c.Path), 0755); e != nil {
			server.Close()
			return nil, e
		}
		if info, e := os.Lstat(c.Path); e == nil {
			if info.Mode()&os.ModeSocket == 0 {
				server.Close()
				return nil, problem("conflict", "control socket path occupied")
			}
			conn, e := net.DialTimeout("unix", c.Path, time.Second)
			if e == nil {
				conn.Close()
				server.Close()
				return nil, problem("conflict", "control socket already listening")
			}
			if e = os.Remove(c.Path); e != nil {
				server.Close()
				return nil, e
			}
		} else if !os.IsNotExist(e) {
			server.Close()
			return nil, e
		}
		listener, e := net.Listen("unix", c.Path)
		if e != nil {
			server.Close()
			return nil, e
		}
		server.listeners = append(server.listeners, listener)
		if e = os.Chmod(c.Path, 0660); e != nil {
			server.Close()
			return nil, e
		}
		if c.GID >= 0 {
			if e = os.Chown(c.Path, -1, c.GID); e != nil {
				server.Close()
				return nil, e
			}
		}
		server.wg.Add(1)
		go func(listener net.Listener, c ControlSocket) {
			defer server.wg.Done()
			for {
				conn, e := listener.Accept()
				if e != nil {
					return
				}
				server.mu.Lock()
				server.connections[conn] = true
				server.wg.Add(1)
				server.mu.Unlock()
				go func() {
					defer server.wg.Done()
					defer conn.Close()
					defer func() { server.mu.Lock(); delete(server.connections, conn); server.mu.Unlock() }()
					conn.SetDeadline(time.Now().Add(24 * time.Hour))
					reader := bufio.NewReaderSize(conn, 64*1024)
					line, e := readRequestLine(reader)
					if e != nil {
						json.NewEncoder(conn).Encode(response(nil, e))
						return
					}
					var req Request
					d := json.NewDecoder(bytes.NewReader(line))
					d.DisallowUnknownFields()
					if e = d.Decode(&req); e != nil {
						json.NewEncoder(conn).Encode(response(nil, problem("invalid", "invalid control JSON")))
						return
					}
					if req.Repository != c.Repository {
						json.NewEncoder(conn).Encode(response(nil, problem("forbidden", "repository outside socket authority")))
						return
					}
					reply := s.Execute(context.Background(), c.Role, req, reader)
					json.NewEncoder(conn).Encode(reply)
				}()
			}
		}(listener, c)
	}
	return server, nil
}
func readRequestLine(r *bufio.Reader) ([]byte, error) {
	line := []byte{}
	for {
		part, e := r.ReadSlice('\n')
		if len(line)+len(part) > 1024*1024 {
			return nil, problem("invalid", "control header too large")
		}
		line = append(line, part...)
		if e == bufio.ErrBufferFull {
			continue
		}
		if e != nil {
			return nil, problem("invalid", "control header requires newline")
		}
		return line, nil
	}
}

func (s *ControlServer) Close() error {
	for _, listener := range s.listeners {
		listener.Close()
	}
	s.mu.Lock()
	for conn := range s.connections {
		conn.Close()
	}
	s.mu.Unlock()
	s.wg.Wait()
	return nil
}

func ControlClient(ctx context.Context, socket string, input io.Reader, output io.Writer) error {
	conn, e := (&net.Dialer{}).DialContext(ctx, "unix", socket)
	if e != nil {
		return e
	}
	defer conn.Close()
	done := make(chan error, 1)
	go func() {
		_, e := io.Copy(conn, input)
		if unix, ok := conn.(*net.UnixConn); ok {
			unix.CloseWrite()
		}
		done <- e
	}()
	var reply Response
	if e = json.NewDecoder(conn).Decode(&reply); e != nil {
		return e
	}
	if e = json.NewEncoder(output).Encode(reply); e != nil {
		return e
	}
	if !reply.OK {
		return reply.Error
	}
	return nil
}
