package reposerver

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const downloadFixtureSize = 4 << 20

// Record the real store's descriptors so completion also checks Close, rather
// than relying on a process-wide descriptor count or a production test hook.
type downloadReader struct {
	*Store
	opened chan *OpenedFile
}

func (r *downloadReader) OpenFile(ctx context.Context, repo, run, path string) (*OpenedFile, error) {
	f, err := r.Store.OpenFile(ctx, repo, run, path)
	if err == nil {
		r.opened <- f
	}
	return f, err
}

func downloadFixture(t *testing.T) (*downloadReader, *atomic.Int64, string, string) {
	t.Helper()
	clock := &atomic.Int64{}
	clock.Store(time.Now().Unix())
	s, err := OpenStore(Options{Root: t.TempDir(), MaxBytes: 32 << 20,
		MaxUploadBytes: 8 << 20, MaxRuns: 8, MaxLease: time.Hour, ExportLease: time.Minute,
		Now: func() time.Time { return time.Unix(clock.Load(), 0).UTC() }})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	a := strings.Repeat("first-image-0123", downloadFixtureSize/16)
	b := strings.Repeat("other-image-4567", downloadFixtureSize/16)
	run := begin(t, s, "downloads", "first", "other")
	uploadItem(t, s, run.Key, "first", "13", a)
	uploadItem(t, s, run.Key, "other", "14", b)
	call(t, s, "producer", "finish", run.Key, map[string]any{}, "")
	publish(t, s, run.Key, "first", "other")
	return &downloadReader{Store: s, opened: make(chan *OpenedFile, 8)}, clock, a, b
}

func downloadObserver(t *testing.T, s *Store) *HTTPObserver {
	t.Helper()
	o, err := NewHTTPObserver(s, ObserverOptions{Repository: "test", Instance: "downloads",
		AccessLog: filepath.Join(t.TempDir(), "private", "access.jsonl"), QueueSize: 32,
		StatsDays: 7, StatsMaxRows: 32, LogFiles: 2, LogMaxBytes: 16384})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		if err := o.Close(ctx); err != nil {
			t.Error(err)
		}
	})
	return o
}

func downloadWait(t *testing.T, label string, done <-chan struct{}) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatalf("%s did not finish within the fixture deadline", label)
	}
}

func downloadProgress(t *testing.T, label string, work func(context.Context) error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- work(ctx) }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("%s: %v", label, err)
		}
	case <-ctx.Done():
		t.Fatalf("%s blocked behind a held download", label)
	}
}

func downloadClosed(t *testing.T, f *OpenedFile) {
	t.Helper()
	if _, err := f.File.Stat(); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("handler retained its file descriptor: %v", err)
	}
}

func downloadBytes(t *testing.T, got []byte, want string) {
	t.Helper()
	if len(got) != len(want) || sha256.Sum256(got) != sha256.Sum256([]byte(want)) {
		t.Fatalf("download length/hash differs: got %d bytes, want %d", len(got), len(want))
	}
}

func downloadStatistics(t *testing.T, s *Store, o *HTTPObserver, requests, size, interrupted int64) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := o.Close(ctx); err != nil {
		t.Fatal(err)
	}
	if o.Health() != (MeasurementHealth{}) {
		t.Fatalf("healthy fixture lost measurement: %+v", o.Health())
	}
	stats, err := s.HTTPStatistics(ctx, "test", "downloads")
	if err != nil {
		t.Fatal(err)
	}
	var count, written, aborted int64
	for _, stat := range stats {
		count += stat.Requests
		written += stat.Bytes
		if stat.Outcome == "interrupted" {
			aborted += stat.Requests
		}
	}
	if count != requests || written != size || aborted != interrupted {
		t.Fatalf("drained measurements: requests=%d bytes=%d interrupted=%d; want %d/%d/%d",
			count, written, aborted, requests, size, interrupted)
	}
}

type downloadGate struct {
	*httptest.ResponseRecorder
	entered chan struct{}
	release chan struct{}
	once    sync.Once
}

func (w *downloadGate) Write(p []byte) (int, error) {
	w.once.Do(func() {
		close(w.entered)
		<-w.release
	})
	return w.ResponseRecorder.Write(p)
}

func TestConcurrentDownloadsProgressAndReclaim(t *testing.T) {
	r, clock, a, b := downloadFixture(t)
	o := downloadObserver(t, r.Store)
	h := NewHTTPHandler(r, HTTPOptions{Repository: "test", Instance: "downloads", Observer: o})
	replacement := begin(t, r.Store, "replacement", "new")
	uploadItem(t, r.Store, replacement.Key, "new", "15", b)
	call(t, r.Store, "producer", "finish", replacement.Key, map[string]any{}, "")

	gates := [2]*downloadGate{}
	done := [2]chan struct{}{make(chan struct{}), make(chan struct{})}
	var release sync.Once
	openGates := func() { release.Do(func() { close(gates[0].release); close(gates[1].release) }) }
	for i, version := range []string{"13", "14"} {
		gates[i] = &downloadGate{ResponseRecorder: httptest.NewRecorder(), entered: make(chan struct{}), release: make(chan struct{})}
		request := httptest.NewRequest("GET", "/v1/vendor/minimal/x86_64/debian/"+version+"/image-archive.tar", nil)
		if i == 1 {
			request.Header.Set("Range", fmt.Sprintf("bytes=1024-%d", len(b)-1025))
		}
		go func(i int) { defer close(done[i]); h.ServeHTTP(gates[i], request) }(i)
	}
	t.Cleanup(func() {
		openGates()
		for _, finished := range done {
			downloadWait(t, "held handler cleanup", finished)
		}
	})
	for _, gate := range gates {
		downloadWait(t, "concurrent first write", gate.entered)
	}
	files := []*OpenedFile{<-r.opened, <-r.opened}
	var metadataBytes int64
	for _, path := range []string{"/v1/INDEX.json", "/dashboard.json"} {
		downloadProgress(t, path, func(ctx context.Context) error {
			w := httptest.NewRecorder()
			req := httptest.NewRequest("GET", path, nil).WithContext(ctx)
			req.Header.Set("User-Agent", "private-concurrent-client")
			h.ServeHTTP(w, req)
			if w.Code != 200 {
				return fmt.Errorf("status %d", w.Code)
			}
			for _, private := range []string{"private-concurrent-client", "client_ip", "socket_peer", "user_agent"} {
				if bytes.Contains(w.Body.Bytes(), []byte(private)) {
					return errors.New("requester detail in public response")
				}
			}
			metadataBytes += int64(w.Body.Len())
			return nil
		})
	}
	downloadProgress(t, "control status", func(ctx context.Context) error {
		resp := r.Execute(ctx, "producer", Request{RequestID: id(), Operation: "status", Repository: "test", Params: encode(map[string]any{})}, nil)
		if !resp.OK {
			return resp.Error
		}
		return nil
	})
	downloadProgress(t, "publication and reclaim", func(ctx context.Context) error {
		view, err := r.Catalog(ctx, "test", "")
		if err != nil {
			return err
		}
		params := PublishParams{Generation: view.Generation, Items: []string{"new"}, Defaults: view.Catalog.Vendors, GC: []GCRule{{Keep: 1}}}
		resp := r.Execute(ctx, "publisher", Request{RequestID: id(), Operation: "publish", Repository: "test", RunKey: replacement.Key, Params: encode(params)}, nil)
		if !resp.OK {
			return resp.Error
		}
		clock.Add(int64((2 * time.Hour) / time.Second))
		for _, op := range []string{"expire", "reclaim"} {
			resp = r.Execute(ctx, "admin", Request{RequestID: id(), Operation: op, Repository: "test", Params: encode(map[string]any{})}, nil)
			if !resp.OK {
				return resp.Error
			}
		}
		return nil
	})
	for _, f := range files {
		if _, err := os.Stat(filepath.Join(r.options.Root, "files", f.Ref.ID)); !os.IsNotExist(err) {
			t.Fatalf("old payload was not physically reclaimed: %v", err)
		}
		if _, err := f.File.Stat(); err != nil {
			t.Fatalf("reclaim invalidated open descriptor: %v", err)
		}
	}
	newView, err := r.Catalog(context.Background(), "test", "")
	if err != nil || len(newView.Catalog.Images) != 1 || newView.Catalog.Images[0].Version != "15" {
		t.Fatalf("new catalog is incoherent: %v", err)
	}
	newResponse := requestHTTP(h, "GET", "/v1/vendor/minimal/x86_64/debian/15/image-archive.tar", nil)
	if newResponse.Code != 200 {
		t.Fatalf("new payload status %d", newResponse.Code)
	}
	downloadBytes(t, newResponse.Body.Bytes(), b)
	newFile := <-r.opened
	downloadClosed(t, newFile)
	for _, finished := range done {
		select {
		case <-finished:
			t.Fatal("transfer completed before its gate was released")
		default:
		}
	}
	openGates()
	for _, finished := range done {
		downloadWait(t, "released download", finished)
	}
	if gates[0].Code != 200 || gates[1].Code != 206 {
		t.Fatal("full/range statuses differ")
	}
	downloadBytes(t, gates[0].Body.Bytes(), a)
	downloadBytes(t, gates[1].Body.Bytes(), b[1024:len(b)-1024])
	if gates[1].Header().Get("Content-Range") != fmt.Sprintf("bytes 1024-%d/%d", len(b)-1025, len(b)) {
		t.Fatal("range metadata differs")
	}
	for _, f := range files {
		downloadClosed(t, f)
	}
	downloadStatistics(t, r.Store, o, 5, metadataBytes+int64(len(a)+2*len(b)-2048), 0)
}

// Flush a bounded prefix to a real TCP client, then hold only this response until
// its request is cancelled. The barrier avoids assumptions about socket buffers.
type downloadSlowWriter struct {
	http.ResponseWriter
	ctx     context.Context
	entered chan struct{}
}

func (w *downloadSlowWriter) Write(p []byte) (int, error) {
	n, err := w.ResponseWriter.Write(p[:min(1024, len(p))])
	if err != nil {
		return n, err
	}
	if err := http.NewResponseController(w.ResponseWriter).Flush(); err != nil {
		return n, err
	}
	close(w.entered)
	<-w.ctx.Done()
	return n, w.ctx.Err()
}

func TestConcurrentDownloadsTCPCancellation(t *testing.T) {
	r, _, a, b := downloadFixture(t)
	o := downloadObserver(t, r.Store)
	h := NewHTTPHandler(r, HTTPOptions{Repository: "test", Instance: "downloads", Observer: o})
	entered, done := make(chan struct{}), make(chan struct{})
	finished := map[string]chan struct{}{
		"/v1/vendor/minimal/x86_64/debian/14/image-archive.tar": make(chan struct{}),
		"/v1/INDEX.json": make(chan struct{}),
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if strings.Contains(req.URL.Path, "/13/") {
			defer close(done)
			w = &downloadSlowWriter{ResponseWriter: w, ctx: req.Context(), entered: entered}
		} else if completed, ok := finished[req.URL.Path]; ok {
			defer close(completed)
		}
		h.ServeHTTP(w, req)
	}))
	t.Cleanup(srv.Close)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	client := srv.Client()
	client.Timeout = 3 * time.Second
	req, err := http.NewRequestWithContext(ctx, "GET", srv.URL+"/v1/vendor/minimal/x86_64/debian/13/image-archive.tar", nil)
	if err != nil {
		t.Fatal(err)
	}
	slow, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { slow.Body.Close() })
	if slow.StatusCode != 200 {
		t.Fatal(slow.StatusCode)
	}
	prefix := make([]byte, 1024)
	if _, err = io.ReadFull(slow.Body, prefix); err != nil {
		t.Fatal(err)
	}
	downloadBytes(t, prefix, a[:1024])
	downloadWait(t, "slow TCP prefix", entered)
	slowFile := <-r.opened
	var fastBytes int64
	for _, path := range []string{"/v1/vendor/minimal/x86_64/debian/14/image-archive.tar", "/v1/INDEX.json"} {
		downloadProgress(t, "independent TCP request", func(ctx context.Context) error {
			req, err := http.NewRequestWithContext(ctx, "GET", srv.URL+path, nil)
			if err != nil {
				return err
			}
			resp, err := client.Do(req)
			if err != nil {
				return err
			}
			defer resp.Body.Close()
			body, err := io.ReadAll(resp.Body)
			if err != nil || resp.StatusCode != 200 {
				return fmt.Errorf("fast response status %d: %v", resp.StatusCode, err)
			}
			if strings.Contains(path, "image-archive") && (len(body) != len(b) || sha256.Sum256(body) != sha256.Sum256([]byte(b))) {
				return errors.New("independent payload differs")
			}
			if strings.HasSuffix(path, "INDEX.json") && !json.Valid(body) {
				return errors.New("index is invalid")
			}
			fastBytes += int64(len(body))
			return nil
		})
		downloadWait(t, "independent TCP handler completion", finished[path])
	}
	select {
	case <-done:
		t.Fatal("slow response ended before client cancellation")
	default:
	}
	cancel()
	slow.Body.Close()
	downloadWait(t, "cancelled TCP handler", done)
	downloadClosed(t, slowFile)
	fastFile := <-r.opened
	downloadClosed(t, fastFile)
	downloadStatistics(t, r.Store, o, 3, fastBytes+1024, 1)
}
