package reposerver

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

type fixtureReader struct {
	file   string
	view   CatalogView
	err    error
	opened int
}

func (f *fixtureReader) Catalog(context.Context, string, string) (CatalogView, error) {
	return f.view, f.err
}
func (f *fixtureReader) Storage(context.Context, string) (StorageSummary, error) {
	return StorageSummary{Bytes: 7, Files: 1, Runs: []RunSummary{{ID: "private-user-agent", Source: Source{Ref: "private-client-ip"}, State: "finished", Items: []WorkItem{{State: "failed", Message: "private-client-ip"}}}}}, nil
}
func (f *fixtureReader) OpenFile(_ context.Context, _ string, _ string, p string) (*OpenedFile, error) {
	if f.err != nil {
		return nil, f.err
	}
	if p != "vendor/minimal/x86_64/debian/13/image-archive.tar" && p != "default/default/x86_64/debian/stable/image-archive.tar" {
		return nil, &Error{Code: "not_found"}
	}
	file, err := os.Open(f.file)
	if err != nil {
		return nil, err
	}
	f.opened++
	img := f.view.Catalog.Images[0]
	return &OpenedFile{File: file, Ref: img.Files["tar"], Tuple: img.Tuple, Path: p, View: f.view}, nil
}
func newFixtureReader(t *testing.T) *fixtureReader {
	t.Helper()
	p := filepath.Join(t.TempDir(), "image.tar")
	if err := os.WriteFile(p, []byte("payload"), 0600); err != nil {
		t.Fatal(err)
	}
	modified := time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)
	return &fixtureReader{file: p, view: CatalogView{Repository: "repo", Generation: "g1", Scope: "public", Modified: modified, Catalog: Catalog{Vendors: map[string]string{"default": "vendor", "vendor": "minimal"}, Images: []Image{{Tuple: Tuple{"vendor", "minimal", "x86_64", "debian", "13"}, Tags: []string{"stable"}, Files: map[string]FileRef{"tar": {ID: "file1", SHA256: "sha1", Size: 7, Format: "tar", Modified: modified}}}}}}}
}
func requestHTTP(h http.Handler, method, p string, headers map[string]string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, p, nil)
	for k, v := range headers {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func TestHTTPStoreArtifactPaths(t *testing.T) {
	store, _ := testStore(t)
	const publicBytes = "public archive\x00\xff"
	const runBytes = "verified run archive\x00\xfe"
	base := begin(t, store, "http-public", "base")
	uploadItem(t, store, base.Key, "base", "13", publicBytes)
	call(t, store, "producer", "finish", base.Key, map[string]any{}, "")
	publish(t, store, base.Key, "base")
	run := begin(t, store, "http-run", "candidate")
	uploadItem(t, store, run.Key, "candidate", "14", runBytes)
	h := NewHTTPHandler(store, HTTPOptions{Repository: "test", Instance: "fixture"})
	runPrefix := "/runs/" + run.Key
	if got := requestHTTP(h, "GET", runPrefix+"/v1/vendor/minimal/x86_64/debian/14/image-archive.tar", nil); got.Code != http.StatusServiceUnavailable {
		t.Fatalf("unsealed run served: %d", got.Code)
	}
	call(t, store, "producer", "finish", run.Key, map[string]any{}, "")
	call(t, store, "producer", "seal", run.Key, map[string]any{}, "")
	for _, tc := range []struct{ path, want string }{
		{"/v1/vendor/minimal/x86_64/debian/13/image-archive.tar", publicBytes},
		{"/v1/default/default/x86_64/debian/latest/image-archive.tar", publicBytes},
		{runPrefix + "/v1/vendor/minimal/x86_64/debian/14/image-archive.tar", runBytes},
		{runPrefix + "/v1/default/default/x86_64/debian/latest/image-archive.tar", runBytes},
		{runPrefix + "/v1/vendor/minimal/x86_64/debian/13/image-archive.tar", publicBytes},
	} {
		t.Run(tc.path, func(t *testing.T) {
			get := requestHTTP(h, "GET", tc.path, nil)
			if get.Code != http.StatusOK || get.Body.String() != tc.want || get.Header().Get("Content-Length") != strconv.Itoa(len(tc.want)) || get.Header().Get("Location") != "" {
				t.Fatalf("GET status=%d headers=%v bytes=%q want=%q", get.Code, get.Header(), get.Body.String(), tc.want)
			}
			head := requestHTTP(h, "HEAD", tc.path, nil)
			if head.Code != http.StatusOK || head.Body.Len() != 0 || head.Header().Get("Content-Length") != strconv.Itoa(len(tc.want)) {
				t.Fatalf("HEAD status=%d headers=%v bytes=%q", head.Code, head.Header(), head.Body.String())
			}
		})
	}
	for _, p := range []string{
		"/v1/vendor/minimal/x86_64/debian/14/image-archive.tar",
		"/v1/vendor/minimal/x86_64/debian/13/image-stream.tar",
		runPrefix + "/v1/vendor/minimal/x86_64/debian/14/image-stream.tar",
		runPrefix + "/v1/vendor/minimal/x86_64/debian/missing/image-archive.tar",
		"/runs/unknown/v1/vendor/minimal/x86_64/debian/13/image-archive.tar",
	} {
		if got := requestHTTP(h, "GET", p, nil); got.Code != http.StatusNotFound {
			t.Fatalf("missing artifact %s status=%d", p, got.Code)
		}
	}
}

func TestHTTPNativeIndexAndFileProtocol(t *testing.T) {
	f := newFixtureReader(t)
	h := NewHTTPHandler(f, HTTPOptions{Repository: "repo", Instance: "one"})
	index := requestHTTP(h, "GET", "/v1/INDEX.json", nil)
	if index.Code != 200 || index.Header().Get("Location") != "" {
		t.Fatal(index.Code, index.Body.String())
	}
	var body struct {
		Vendors map[string]string
		Images  []struct {
			Version string
			Image   map[string]string
		}
	}
	if err := json.Unmarshal(index.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Vendors["default"] != "vendor" || body.Images[0].Image["tar"] != "vendor/minimal/x86_64/debian/13/image-archive.tar" {
		t.Fatal(index.Body.String())
	}
	for _, prefix := range []string{"", "/runs/sealed"} {
		for _, p := range []string{"/v1/vendor/minimal/x86_64/debian/13/image-archive.tar", "/v1/default/default/x86_64/debian/stable/image-archive.tar"} {
			get := requestHTTP(h, "GET", prefix+p, nil)
			if get.Code != 200 || get.Body.String() != "payload" || get.Header().Get("Content-Length") != "7" {
				t.Fatal(get.Code, get.Header(), get.Body.String())
			}
			head := requestHTTP(h, "HEAD", prefix+p, nil)
			if head.Code != 200 || head.Body.Len() != 0 || head.Header().Get("Content-Length") != "7" {
				t.Fatal(head.Code, head.Header(), head.Body.String())
			}
			ranged := requestHTTP(h, "GET", prefix+p, map[string]string{"Range": "bytes=2-4"})
			if ranged.Code != 206 || ranged.Body.String() != "ylo" || ranged.Header().Get("Content-Range") != "bytes 2-4/7" {
				t.Fatal(ranged.Code, ranged.Header(), ranged.Body.String())
			}
		}
	}
}

func TestHTTPFreshnessAfterSameSecondReplacement(t *testing.T) {
	f := newFixtureReader(t)
	h := NewHTTPHandler(f, HTTPOptions{Repository: "repo"})
	p := "/v1/vendor/minimal/x86_64/debian/13/image-archive.tar"
	first := requestHTTP(h, "GET", p, nil)
	date := first.Header().Get("Last-Modified")
	etag := first.Header().Get("ETag")
	if date == "" || etag == "" {
		t.Fatal(first.Header())
	}
	if got := requestHTTP(h, "GET", "/runs/sealed"+p, map[string]string{"If-Modified-Since": date}); got.Code != 304 {
		t.Fatal(got.Code)
	}
	if err := os.WriteFile(f.file, []byte("changed"), 0600); err != nil {
		t.Fatal(err)
	}
	img := &f.view.Catalog.Images[0]
	ref := img.Files["tar"]
	ref.ID = "file2"
	ref.SHA256 = "sha2"
	img.Files["tar"] = ref
	for _, headers := range []map[string]string{{"If-Modified-Since": date}, {"If-None-Match": etag}, {"If-Range": date, "Range": "bytes=2-4"}} {
		got := requestHTTP(h, "GET", p, headers)
		if got.Code != 200 || got.Body.String() != "changed" {
			t.Fatal(got.Code, got.Body.String())
		}
	}
	current := requestHTTP(h, "GET", p, nil)
	if got := requestHTTP(h, "GET", p, map[string]string{"If-None-Match": current.Header().Get("ETag")}); got.Code != 304 {
		t.Fatal(got.Code)
	}
}

func TestHTTPPathsErrorsAndPublicPrivacy(t *testing.T) {
	f := newFixtureReader(t)
	h := NewHTTPHandler(f, HTTPOptions{Repository: "repo", Instance: "one"})
	for _, p := range []string{"/", "/dashboard.json", "/v1/", "/runs/sealed/"} {
		got := requestHTTP(h, "GET", p, map[string]string{"User-Agent": "private-user-agent", "X-Real-IP": "private-client-ip"})
		if got.Code != 200 {
			t.Fatal(p, got.Code, got.Body.String())
		}
		if strings.Contains(got.Body.String(), "private-") {
			t.Fatal("private requester or raw run fields exposed", got.Body.String())
		}
	}
	for _, p := range []string{"/v1/../secret", "/v1/%2e%2e/secret", "/v1//secret", "/v1/%5csecret"} {
		if got := requestHTTP(h, "GET", p, nil); got.Code != 400 {
			t.Fatal(p, got.Code)
		}
	}
	if got := requestHTTP(h, "POST", "/v1/INDEX.json", nil); got.Code != 405 {
		t.Fatal(got.Code)
	}
	for code, status := range map[string]int{"not_ready": 503, "expired": 410, "not_found": 404} {
		f.err = &Error{Code: code, Message: "private-client-ip"}
		got := requestHTTP(h, "GET", "/runs/missing/v1/INDEX.json", nil)
		if got.Code != status || strings.Contains(got.Body.String(), "private-") {
			t.Fatal(got.Code, got.Body.String())
		}
	}
}

func TestHTTPProxyTrust(t *testing.T) {
	h := &repositoryHTTP{opts: HTTPOptions{ClientIPHeader: "X-Repo-Client-IP", TrustedProxies: []netip.Prefix{netip.MustParsePrefix("192.0.2.1/32")}}}
	for _, test := range []struct{ peer, header, want string }{{"192.0.2.1:12", "2001:db8::5", "2001:db8::5"}, {"198.51.100.9:12", "203.0.113.7", "198.51.100.9"}, {"192.0.2.1:12", "203.0.113.7, 198.51.100.3", "192.0.2.1"}, {"192.0.2.1:12", "not-an-ip", "192.0.2.1"}} {
		r := httptest.NewRequest("GET", "/", nil)
		r.RemoteAddr = test.peer
		r.Header.Set("X-Repo-Client-IP", test.header)
		r.Header.Set("X-Forwarded-For", "203.0.113.8")
		got, _ := h.requester(r)
		if got != test.want {
			t.Fatal(test, got)
		}
		r.Header.Add("X-Repo-Client-IP", "203.0.113.1")
		got, _ = h.requester(r)
		if strings.Contains(got, ",") {
			t.Fatal(got)
		}
	}
}

func TestHTTPPrivateJSONLAndLogFailureDoesNotFailDownload(t *testing.T) {
	f := newFixtureReader(t)
	dir := t.TempDir()
	p := filepath.Join(dir, "private", "access.jsonl")
	o, err := NewHTTPObserver(nil, ObserverOptions{Repository: "repo", Instance: "one", AccessLog: p, QueueSize: 8, StatsDays: 7, StatsMaxRows: 100, LogFiles: 2, LogMaxBytes: 16384})
	if err != nil {
		t.Fatal(err)
	}
	h := NewHTTPHandler(f, HTTPOptions{Repository: "repo", Instance: "one", Observer: o})
	got := requestHTTP(h, "GET", "/v1/vendor/minimal/x86_64/debian/13/image-archive.tar?secret=omit", map[string]string{"User-Agent": "quote\" newline\n" + strings.Repeat("x", 1024)})
	if got.Code != 200 {
		t.Fatal(got.Code)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := o.Close(ctx); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(p)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal(info, err)
	}
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	var e AccessEvent
	if err := json.Unmarshal(b, &e); err != nil {
		t.Fatal(err, string(b))
	}
	if e.Schema != 1 || e.Bytes != 7 || e.Status != 200 || e.Outcome != "complete" || e.Tuple == nil || e.Timestamp.Location() != time.UTC || len(e.UserAgent) > 512 || strings.Contains(string(b), "secret=") {
		t.Fatal(string(b))
	}
	failed := &HTTPObserver{opts: ObserverOptions{Repository: "repo"}, log: failedLog{}, queue: make(chan AccessEvent, 2), done: make(chan struct{})}
	go failed.run()
	h = NewHTTPHandler(f, HTTPOptions{Repository: "repo", Observer: failed})
	got = requestHTTP(h, "GET", "/v1/vendor/minimal/x86_64/debian/13/image-archive.tar", nil)
	if got.Code != 200 || got.Body.String() != "payload" {
		t.Fatal(got.Code)
	}
	if err := failed.Close(ctx); err != nil {
		t.Fatal(err)
	}
	if failed.Health().LogFailures != 1 {
		t.Fatal(failed.Health())
	}
}

type failedLog struct{}

func (failedLog) Write([]byte) (int, error) { return 0, errors.New("disk full") }
func (failedLog) Close() error              { return nil }

type stalledLog struct {
	start   chan struct{}
	release chan struct{}
	once    sync.Once
}

func (l *stalledLog) Write(b []byte) (int, error) {
	l.once.Do(func() { close(l.start) })
	<-l.release
	return len(b), nil
}
func (l *stalledLog) Close() error { return nil }

func TestHTTPQueuePressureAndInterruption(t *testing.T) {
	f := newFixtureReader(t)
	l := &stalledLog{start: make(chan struct{}), release: make(chan struct{})}
	o := &HTTPObserver{log: l, queue: make(chan AccessEvent, 1), done: make(chan struct{})}
	go o.run()
	o.Observe(AccessEvent{})
	<-l.start
	o.Observe(AccessEvent{})
	o.Observe(AccessEvent{})
	if o.Health().Dropped != 1 {
		t.Fatal(o.Health())
	}
	h := NewHTTPHandler(f, HTTPOptions{Observer: o})
	w := &failingResponse{header: make(http.Header)}
	r := httptest.NewRequest("GET", "/v1/vendor/minimal/x86_64/debian/13/image-archive.tar", nil)
	h.ServeHTTP(w, r)
	close(l.release)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := o.Close(ctx); err != nil {
		t.Fatal(err)
	}
	// A response writer error never becomes a second attempted error response.
	if w.status != 200 {
		t.Fatal(w.status)
	}
}

type bufferLog struct{ bytes.Buffer }

func (*bufferLog) Close() error { return nil }

func TestHTTPInterruptedResponseEvent(t *testing.T) {
	f := newFixtureReader(t)
	log := &bufferLog{}
	o := &HTTPObserver{log: log, queue: make(chan AccessEvent, 2), done: make(chan struct{})}
	go o.run()
	w := &failingResponse{header: make(http.Header)}
	NewHTTPHandler(f, HTTPOptions{Observer: o}).ServeHTTP(w, httptest.NewRequest("GET", "/v1/vendor/minimal/x86_64/debian/13/image-archive.tar", nil))
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := o.Close(ctx); err != nil {
		t.Fatal(err)
	}
	var e AccessEvent
	if err := json.Unmarshal(log.Bytes(), &e); err != nil {
		t.Fatal(err)
	}
	if e.Outcome != "interrupted" || e.Bytes != 0 || e.Status != 200 {
		t.Fatal(e)
	}
}

func TestHTTPAccessLogRotationAndInterruptedTail(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "private")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, "access.jsonl")
	if err := os.WriteFile(p, []byte("{\"old\":true}\n{\"interrupted\":"), 0600); err != nil {
		t.Fatal(err)
	}
	l, err := openAccessLog(p, 16384, 2)
	if err != nil {
		t.Fatal(err)
	}
	line := []byte("{\"event\":\"" + strings.Repeat("x", 8000) + "\"}\n")
	for i := 0; i < 5; i++ {
		if _, err := l.Write(line); err != nil {
			t.Fatal(err)
		}
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{p, p + ".1"} {
		info, err := os.Stat(name)
		if err != nil || info.Size() > 16384 || info.Mode().Perm() != 0600 {
			t.Fatal(info, err)
		}
		data, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		for _, record := range bytes.Split(bytes.TrimSpace(data), []byte("\n")) {
			if !json.Valid(record) {
				t.Fatal("invalid retained JSON line")
			}
		}
	}
	if _, err := os.Stat(p + ".2"); !os.IsNotExist(err) {
		t.Fatal("retention count exceeded")
	}
}

type partialLogFile struct {
	*os.File
	failed        bool
	shortWrite    bool
	truncateFails bool
}

func (f *partialLogFile) Write(b []byte) (int, error) {
	if f.failed {
		return f.File.Write(b)
	}
	f.failed = true
	n, err := f.File.Write(b[:len(b)/2])
	if err != nil {
		return n, err
	}
	if f.shortWrite {
		return n, nil
	}
	return n, io.ErrUnexpectedEOF
}

func (f *partialLogFile) Truncate(n int64) error {
	if f.truncateFails {
		return io.ErrUnexpectedEOF
	}
	return f.File.Truncate(n)
}

func TestHTTPPartialAccessEventRecoveryAndRotation(t *testing.T) {
	for _, tc := range []struct {
		name               string
		short, repairFails bool
	}{
		{"partial_error", false, false},
		{"short_write", true, false},
		{"repair_on_reopen", false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := filepath.Join(t.TempDir(), "private")
			if err := os.Mkdir(dir, 0700); err != nil {
				t.Fatal(err)
			}
			p := filepath.Join(dir, "access.jsonl")
			l, err := openAccessLog(p, 16384, 2)
			if err != nil {
				t.Fatal(err)
			}
			prefill, _ := json.Marshal(AccessEvent{Schema: 1, RequestID: "prefill", UserAgent: strings.Repeat("x", 6500)})
			if _, err := l.Write(append(prefill, '\n')); err != nil {
				t.Fatal(err)
			}
			l.file = &partialLogFile{File: l.file.(*os.File), shortWrite: tc.short, truncateFails: tc.repairFails}
			o := &HTTPObserver{log: l, queue: make(chan AccessEvent, 8), done: make(chan struct{})}
			go o.run()
			o.Observe(AccessEvent{Schema: 1, RequestID: "incomplete-event", UserAgent: strings.Repeat("x", 6500)})
			for i := 0; i < 3; i++ {
				o.Observe(AccessEvent{Schema: 1, RequestID: strconv.Itoa(i), UserAgent: strings.Repeat("x", 6500)})
			}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			if err := o.Close(ctx); err != nil {
				t.Fatal(err)
			}
			if o.Health().LogFailures != 1 {
				t.Fatal(o.Health())
			}
			retained := 0
			for _, name := range []string{p, p + ".1"} {
				data, err := os.ReadFile(name)
				if err != nil {
					t.Fatal(err)
				}
				if len(data) > 16384 || len(data) == 0 || data[len(data)-1] != '\n' {
					t.Fatal("invalid retained file bounds")
				}
				for _, line := range bytes.Split(bytes.TrimSpace(data), []byte("\n")) {
					var e AccessEvent
					if err := json.Unmarshal(line, &e); err != nil {
						t.Fatalf("malformed retained event: %v", err)
					}
					if e.Schema != 1 || e.RequestID == "incomplete-event" {
						t.Fatal("incomplete event retained", e)
					}
					retained++
				}
			}
			if retained != 4 {
				t.Fatalf("recovered events lost: %d", retained)
			}
		})
	}
}

type failingResponse struct {
	header http.Header
	status int
}

func (w *failingResponse) Header() http.Header       { return w.header }
func (w *failingResponse) WriteHeader(s int)         { w.status = s }
func (w *failingResponse) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }
