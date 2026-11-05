package reposerver

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"path"
	"sort"
	"strings"
	"time"
)

// HTTPOptions selects one repository. Administrative operations use Unix sockets.
type HTTPOptions struct {
	Repository     string
	Instance       string
	TrustedProxies []netip.Prefix
	ClientIPHeader string
	Observer       *HTTPObserver
}

type repositoryHTTP struct {
	reader Reader
	opts   HTTPOptions
}

func NewHTTPHandler(reader Reader, options HTTPOptions) http.Handler {
	return &repositoryHTTP{reader: reader, opts: options}
}

func (h *repositoryHTTP) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	var id [16]byte
	_, _ = rand.Read(id[:])
	e := AccessEvent{Schema: 1, Timestamp: start.UTC(), RequestID: hex.EncodeToString(id[:]),
		Repository: h.opts.Repository, Instance: h.opts.Instance, Method: bounded(r.Method, 32),
		Path: bounded(r.URL.Path, 2048), UserAgent: bounded(r.UserAgent(), 512),
		Range: bounded(r.Header.Get("Range"), 256), Scope: "public", Kind: "other"}
	e.ClientIP, e.SocketPeer = h.requester(r)
	w.Header().Set("X-Request-ID", e.RequestID)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("Cache-Control", "no-cache")
	rw := &responseCapture{ResponseWriter: w}
	defer func() {
		p := recover()
		if p != nil || r.Context().Err() != nil || rw.err != nil {
			e.Outcome = "interrupted"
		} else {
			e.Outcome = "complete"
		}
		if rw.status == 0 && p == nil && r.Context().Err() == nil {
			rw.status = http.StatusOK
		}
		e.Status, e.Bytes = rw.status, rw.bytes
		e.DurationMS = time.Since(start).Milliseconds()
		e.ContentRange = bounded(w.Header().Get("Content-Range"), 256)
		if h.opts.Observer != nil {
			h.opts.Observer.Observe(e)
		}
		if p != nil {
			panic(p)
		}
	}()
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		rw.Header().Set("Allow", "GET, HEAD")
		http.Error(rw, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !safeHTTPPath(r.URL.Path) {
		http.Error(rw, "Invalid path", http.StatusBadRequest)
		return
	}
	p, run := r.URL.Path, ""
	if strings.HasPrefix(p, "/runs/") {
		parts := strings.SplitN(strings.TrimPrefix(p, "/runs/"), "/", 2)
		if len(parts) != 2 || parts[0] == "" {
			http.NotFound(rw, r)
			return
		}
		run, p = parts[0], "/"+parts[1]
		e.Scope, e.RunKey = "run", bounded(run, 256)
	}
	if p == "/" || p == "/dashboard.json" || strings.HasSuffix(p, "/") && strings.HasPrefix(p, "/v1/") {
		e.Kind = "dashboard"
		h.dashboard(rw, r, run, p)
		return
	}
	if p == "/v1/INDEX.json" {
		e.Kind = "index"
		view, err := h.reader.Catalog(r.Context(), h.opts.Repository, run)
		if err != nil {
			h.readerError(rw, r, err)
			return
		}
		body, err := nativeIndex(view.Catalog)
		if err != nil {
			h.readerError(rw, r, err)
			return
		}
		sum := sha256.Sum256(body)
		rw.Header().Set("Content-Type", "application/json")
		rw.Header().Set("ETag", fmt.Sprintf(`"%x"`, sum))
		http.ServeContent(rw, conditionalRequest(r, run == ""), "INDEX.json", view.Modified, bytes.NewReader(body))
		return
	}
	if !strings.HasPrefix(p, "/v1/") {
		http.NotFound(rw, r)
		return
	}
	e.Kind = "artifact"
	// The Reader resolves native tuple-relative paths; /v1 is the HTTP schema
	// prefix and belongs only to this routing boundary.
	f, err := h.reader.OpenFile(r.Context(), h.opts.Repository, run, strings.TrimPrefix(p, "/v1/"))
	if err != nil {
		h.readerError(rw, r, err)
		return
	}
	defer f.File.Close()
	e.Tuple, e.Format, e.FileID = &f.Tuple, f.Ref.Format, f.Ref.ID
	rw.Header().Set("Content-Type", "application/x-tar")
	sum := sha256.Sum256([]byte(f.Ref.ID + ":" + f.Ref.SHA256))
	rw.Header().Set("ETag", fmt.Sprintf(`"%x"`, sum))
	http.ServeContent(rw, conditionalRequest(r, run == ""), path.Base(p), f.Ref.Modified, f.File)
}

func safeHTTPPath(p string) bool {
	if p == "" || !strings.HasPrefix(p, "/") || strings.ContainsAny(p, "\\\x00\r\n") || strings.Contains(p, "//") {
		return false
	}
	for _, c := range strings.Split(p, "/") {
		if c == "." || c == ".." {
			return false
		}
	}
	return true
}

// Public Last-Modified dates have one-second precision. Never use them to assert
// unchanged bytes after same-second replacement or rollback. Strong ETags still
// permit validation, and sealed run dates are immutable.
func conditionalRequest(r *http.Request, public bool) *http.Request {
	if !public {
		return r
	}
	c := r.Clone(r.Context())
	c.Header = r.Header.Clone()
	c.Header.Del("If-Modified-Since")
	if ir := c.Header.Get("If-Range"); ir != "" && !strings.HasPrefix(ir, `"`) {
		c.Header.Del("Range")
		c.Header.Del("If-Range")
	}
	return c
}

func (h *repositoryHTTP) requester(r *http.Request) (string, string) {
	peer, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		peer = r.RemoteAddr
	}
	addr, err := netip.ParseAddr(peer)
	if err != nil {
		return "", bounded(peer, 128)
	}
	addr = addr.Unmap()
	peer = addr.String()
	for _, prefix := range h.opts.TrustedProxies {
		if prefix.Contains(addr) && h.opts.ClientIPHeader != "" {
			// The edge replaces this single header. Chains, duplicate fields and
			// ports are rejected rather than interpreted as requester identity.
			values := r.Header.Values(h.opts.ClientIPHeader)
			if len(values) == 1 {
				if client, err := netip.ParseAddr(values[0]); err == nil && client.Zone() == "" {
					return client.Unmap().String(), peer
				}
			}
			break
		}
	}
	return peer, peer
}

func (h *repositoryHTTP) readerError(w http.ResponseWriter, r *http.Request, err error) {
	status, message := http.StatusInternalServerError, "Repository unavailable"
	var e *Error
	if errors.As(err, &e) {
		switch e.Code {
		case "not_found":
			status, message = http.StatusNotFound, "Not found"
		case "not_ready":
			status, message = http.StatusServiceUnavailable, "Repository is not ready"
			w.Header().Set("Retry-After", "30")
		case "expired":
			status, message = http.StatusGone, "Repository has expired"
		case "invalid":
			status, message = http.StatusBadRequest, "Invalid path"
		case "forbidden":
			status, message = http.StatusForbidden, "Forbidden"
		}
	}
	http.Error(w, message, status)
}

type indexImage struct {
	Tuple
	Tags  []string          `json:"tags"`
	Image map[string]string `json:"image"`
}

func nativeIndex(c Catalog) ([]byte, error) {
	images := make([]indexImage, 0, len(c.Images))
	for _, img := range c.Images {
		files := map[string]string{}
		for format := range img.Files {
			name := formatFilename(format)
			if name == "" {
				return nil, fmt.Errorf("unsupported image format")
			}
			files[format] = tuplePath(img.Tuple) + "/" + name
		}
		tags := append([]string{}, img.Tags...)
		sort.Strings(tags)
		images = append(images, indexImage{img.Tuple, tags, files})
	}
	sort.Slice(images, func(i, j int) bool { return httpTupleLess(images[i].Tuple, images[j].Tuple) })
	return json.Marshal(struct {
		Vendors map[string]string `json:"vendors"`
		Images  []indexImage      `json:"images"`
	}{c.Vendors, images})
}

func tuplePath(t Tuple) string {
	return strings.Join([]string{t.Vendor, t.Variant, t.Arch, t.Distribution, t.Version}, "/")
}

func httpTupleLess(a, b Tuple) bool {
	x := []string{a.Vendor, a.Variant, a.Arch, a.Distribution, a.Version}
	y := []string{b.Vendor, b.Variant, b.Arch, b.Distribution, b.Version}
	for i := range x {
		if x[i] != y[i] {
			return x[i] < y[i]
		}
	}
	return false
}

func formatFilename(format string) string {
	switch format {
	case "tar":
		return "image-archive.tar"
	case "zfs":
		return "image-stream.tar"
	}
	return ""
}

type responseCapture struct {
	http.ResponseWriter
	status int
	bytes  int64
	err    error
}

func (w *responseCapture) WriteHeader(status int) {
	if w.status == 0 {
		w.status = status
		w.ResponseWriter.WriteHeader(status)
	}
}

func (w *responseCapture) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	n, err := w.ResponseWriter.Write(b)
	w.bytes += int64(n)
	if err != nil && w.err == nil {
		w.err = err
	}
	return n, err
}

func (w *responseCapture) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func bounded(s string, n int) string {
	s = strings.ToValidUTF8(s, "\ufffd")
	if len(s) > n {
		return strings.ToValidUTF8(s[:n], "")
	}
	return s
}
