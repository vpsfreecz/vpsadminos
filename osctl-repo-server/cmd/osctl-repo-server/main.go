package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"os/user"
	"strconv"
	"strings"
	"syscall"
	"time"

	reposerver "github.com/vpsfreecz/vpsadminos/osctl-repo-server"
)

type repeated []string

func (v *repeated) String() string     { return strings.Join(*v, ",") }
func (v *repeated) Set(s string) error { *v = append(*v, s); return nil }
func groupID(name string) (int, error) {
	if name == "" {
		return -1, nil
	}
	group, e := user.LookupGroup(name)
	if e != nil {
		return 0, e
	}
	return strconv.Atoi(group.Gid)
}
func main() {
	if e := run(); e != nil {
		slog.Error("command failed", "error", e)
		os.Exit(1)
	}
}
func run() error {
	if len(os.Args) < 2 {
		return errors.New("usage: osctl-repo-server serve|ctl [flags]")
	}
	if os.Args[1] == "ctl" {
		flags := flag.NewFlagSet("ctl", flag.ContinueOnError)
		socket := flags.String("socket", "", "role-specific local socket")
		if e := flags.Parse(os.Args[2:]); e != nil {
			return e
		}
		if *socket == "" || flags.NArg() != 0 {
			return errors.New("ctl requires --socket and JSON request on stdin")
		}
		return reposerver.ControlClient(context.Background(), *socket, os.Stdin, os.Stdout)
	}
	if os.Args[1] != "serve" {
		return errors.New("unknown command")
	}
	flags := flag.NewFlagSet("serve", flag.ContinueOnError)
	root := flags.String("root", "", "private storage directory")
	listen := flags.String("listen", "", "HTTP listen address")
	repository := flags.String("repository", "", "repository ID")
	instance := flags.String("instance", "", "instance ID")
	producer := flags.String("producer-socket", "", "producer socket")
	publisher := flags.String("publisher-socket", "", "publisher socket")
	admin := flags.String("admin-socket", "", "administrator socket")
	producerGroup := flags.String("producer-group", "", "producer socket group")
	publisherGroup := flags.String("publisher-group", "", "publisher socket group")
	adminGroup := flags.String("admin-group", "", "administrator socket group")
	maxBytes := flags.Int64("max-bytes", 0, "managed payload byte quota")
	reserve := flags.Int64("reserve-bytes", 0, "filesystem free bytes reserved")
	maxUpload := flags.Int64("max-upload-bytes", 0, "maximum individual upload")
	maxRuns := flags.Int("max-runs", 0, "maximum retained runs")
	maxLease := flags.Duration("max-lease", 0, "maximum run lease")
	exportLease := flags.Duration("export-lease", 0, "maximum export/rollback retention")
	accessLog := flags.String("access-log", "", "private JSONL log path")
	logBytes := flags.Int64("access-log-max-bytes", 0, "rotation byte limit")
	logFiles := flags.Int("access-log-files", 0, "retained log files")
	statsDays := flags.Int("stats-days", 365, "retained statistics days")
	statsRows := flags.Int("stats-max-rows", 0, "bounded aggregate row count")
	eventQueue := flags.Int("event-queue", 0, "bounded measurement queue")
	clientHeader := flags.String("client-ip-header", "", "trusted edge client address header")
	var proxyArgs repeated
	flags.Var(&proxyArgs, "trusted-proxy", "trusted proxy network prefix (repeatable)")
	if e := flags.Parse(os.Args[2:]); e != nil {
		return e
	}
	if flags.NArg() != 0 || *listen == "" || *repository == "" || *instance == "" {
		return errors.New("explicit listen/repository/instance required")
	}
	proxies := []netip.Prefix{}
	for _, value := range proxyArgs {
		prefix, e := netip.ParsePrefix(value)
		if e != nil {
			return e
		}
		proxies = append(proxies, prefix)
	}
	store, e := reposerver.OpenStore(reposerver.Options{Root: *root, MaxBytes: *maxBytes, ReservedBytes: *reserve, MaxUploadBytes: *maxUpload, MaxRuns: *maxRuns, MaxLease: *maxLease, ExportLease: *exportLease})
	if e != nil {
		return e
	}
	defer store.Close()
	observer, e := reposerver.NewHTTPObserver(store, reposerver.ObserverOptions{Repository: *repository, Instance: *instance, AccessLog: *accessLog, QueueSize: *eventQueue, StatsDays: *statsDays, StatsMaxRows: *statsRows, LogFiles: *logFiles, LogMaxBytes: *logBytes})
	if e != nil {
		return e
	}
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if e := observer.Close(ctx); e != nil {
			slog.Error("measurement shutdown incomplete", "error", e)
		}
	}()
	config := []reposerver.ControlSocket{}
	for _, entry := range []struct{ path, group, role string }{{*producer, *producerGroup, "producer"}, {*publisher, *publisherGroup, "publisher"}, {*admin, *adminGroup, "admin"}} {
		gid, e := groupID(entry.group)
		if e != nil {
			return e
		}
		config = append(config, reposerver.ControlSocket{Path: entry.path, GID: gid, Role: entry.role, Repository: *repository})
	}
	control, e := store.ListenControl(config)
	if e != nil {
		return e
	}
	defer control.Close()
	server := &http.Server{Addr: *listen, Handler: reposerver.NewHTTPHandler(store, reposerver.HTTPOptions{Repository: *repository, Instance: *instance, TrustedProxies: proxies, ClientIPHeader: *clientHeader, Observer: observer}), ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 2 * time.Minute}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	done := make(chan error, 1)
	go func() { done <- server.ListenAndServe() }()
	slog.Info("repository service listening", "address", *listen, "repository", *repository, "instance", *instance)
	select {
	case e := <-done:
		if !errors.Is(e, http.ErrServerClosed) {
			return e
		}
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if e := server.Shutdown(shutdown); e != nil {
			return fmt.Errorf("HTTP shutdown: %w", e)
		}
	}
	return nil
}
