package reposerver

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// AccessEvent is the private, versioned JSON Lines schema. Query strings and
// arbitrary headers are deliberately absent. Public aggregates use AggregateKey.
type AccessEvent struct {
	Schema       int       `json:"schema"`
	Timestamp    time.Time `json:"timestamp"`
	RequestID    string    `json:"request_id"`
	Repository   string    `json:"repository"`
	Instance     string    `json:"instance"`
	ClientIP     string    `json:"client_ip"`
	SocketPeer   string    `json:"socket_peer"`
	Method       string    `json:"method"`
	Path         string    `json:"path"`
	Status       int       `json:"status"`
	Bytes        int64     `json:"bytes"`
	DurationMS   int64     `json:"duration_ms"`
	Scope        string    `json:"scope"`
	RunKey       string    `json:"run_key,omitempty"`
	Kind         string    `json:"kind"`
	Tuple        *Tuple    `json:"tuple,omitempty"`
	Format       string    `json:"format,omitempty"`
	FileID       string    `json:"file_id,omitempty"`
	UserAgent    string    `json:"user_agent"`
	Range        string    `json:"range,omitempty"`
	ContentRange string    `json:"content_range,omitempty"`
	Outcome      string    `json:"outcome"`
}

type ObserverOptions struct {
	Repository   string
	Instance     string
	AccessLog    string
	QueueSize    int
	StatsDays    int
	StatsMaxRows int
	LogFiles     int
	LogMaxBytes  int64
}

type HTTPStatisticsStore interface {
	RecordHTTP(context.Context, AccessEvent, int, int) error
	HTTPStatistics(context.Context, string, string) ([]DailyStatistic, error)
}

type MeasurementHealth struct {
	Dropped       uint64 `json:"dropped"`
	LogFailures   uint64 `json:"log_failures"`
	StatsFailures uint64 `json:"stats_failures"`
}

// HTTPObserver has one bounded queue. A slow or failed log/statistics writer
// cannot apply backpressure to responses. Close drains it until ctx expires.
type HTTPObserver struct {
	store         HTTPStatisticsStore
	opts          ObserverOptions
	log           io.WriteCloser
	queue         chan AccessEvent
	done          chan struct{}
	mu            sync.RWMutex
	closed        bool
	dropped       atomic.Uint64
	logFailures   atomic.Uint64
	statsFailures atomic.Uint64
	statsMu       sync.RWMutex
	stats         []DailyStatistic
}

func NewHTTPObserver(store HTTPStatisticsStore, opts ObserverOptions) (*HTTPObserver, error) {
	if opts.Repository == "" || opts.Instance == "" || opts.QueueSize < 1 || opts.QueueSize > 65536 ||
		opts.StatsDays < 1 || opts.StatsDays > 3660 || opts.StatsMaxRows < 1 || opts.StatsMaxRows > 1000000 ||
		opts.LogFiles < 1 || opts.LogFiles > 1000 || opts.LogMaxBytes < 16384 || !filepath.IsAbs(opts.AccessLog) {
		return nil, fmt.Errorf("explicit bounded HTTP measurement options required")
	}
	// Open in the worker. A permission or disk failure must be observable as
	// dropped logging, without preventing the public reader from starting.
	l := &lazyAccessLog{path: opts.AccessLog, max: opts.LogMaxBytes, files: opts.LogFiles}
	o := &HTTPObserver{store: store, opts: opts, log: l, queue: make(chan AccessEvent, opts.QueueSize), done: make(chan struct{})}
	go o.run()
	return o, nil
}

func (o *HTTPObserver) Observe(e AccessEvent) {
	o.mu.RLock()
	defer o.mu.RUnlock()
	if o.closed {
		o.dropped.Add(1)
		return
	}
	select {
	case o.queue <- e:
	default:
		o.dropped.Add(1)
	}
}

func (o *HTTPObserver) Health() MeasurementHealth {
	return MeasurementHealth{o.dropped.Load(), o.logFailures.Load(), o.statsFailures.Load()}
}

func (o *HTTPObserver) Statistics() []DailyStatistic {
	o.statsMu.RLock()
	defer o.statsMu.RUnlock()
	return recentStatistics(o.stats, o.opts.StatsDays, time.Now())
}

func (o *HTTPObserver) Close(ctx context.Context) error {
	o.mu.Lock()
	if !o.closed {
		o.closed = true
		close(o.queue)
	}
	o.mu.Unlock()
	select {
	case <-o.done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (o *HTTPObserver) refresh() {
	if o.store == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	stats, err := o.store.HTTPStatistics(ctx, o.opts.Repository, o.opts.Instance)
	if err != nil {
		o.statsFailures.Add(1)
		return
	}
	o.statsMu.Lock()
	o.stats = recentStatistics(stats, o.opts.StatsDays, time.Now())
	o.statsMu.Unlock()
}

func (o *HTTPObserver) run() {
	defer close(o.done)
	defer o.log.Close()
	o.refresh()
	for e := range o.queue {
		// Encoder retains its first writer error. Use a fresh one per event so
		// a repaired file can accept subsequent complete records.
		if err := json.NewEncoder(o.log).Encode(e); err != nil {
			o.logFailures.Add(1)
		}
		if o.store != nil {
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			err := o.store.RecordHTTP(ctx, e, o.opts.StatsDays, o.opts.StatsMaxRows)
			cancel()
			if err != nil {
				o.statsFailures.Add(1)
			}
		}
		// Refresh once the current burst drains, rather than querying on the
		// request path or after every request under load.
		if len(o.queue) == 0 {
			o.refresh()
		}
	}
}

type accessLog struct {
	path  string
	max   int64
	files int
	file  accessLogFile
	size  int64
}

type accessLogFile interface {
	io.WriteCloser
	Truncate(int64) error
}

type lazyAccessLog struct {
	path  string
	max   int64
	files int
	log   *accessLog
}

func (l *lazyAccessLog) Write(b []byte) (int, error) {
	if l.log == nil {
		var err error
		l.log, err = openAccessLog(l.path, l.max, l.files)
		if err != nil {
			l.log = nil
			return 0, err
		}
	}
	return l.log.Write(b)
}

func (l *lazyAccessLog) Close() error {
	if l.log != nil {
		return l.log.Close()
	}
	return nil
}

func openAccessLog(p string, max int64, files int) (*accessLog, error) {
	dir := filepath.Dir(p)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return nil, fmt.Errorf("access log directory must be private")
	}
	l := &accessLog{path: p, max: max, files: files}
	err = l.open()
	return l, err
}

func (l *accessLog) open() error {
	f, err := os.OpenFile(l.path, os.O_RDWR|os.O_APPEND|os.O_CREATE|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0600)
	if err != nil {
		return err
	}
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() {
		f.Close()
		return fmt.Errorf("access log must be a regular file")
	}
	if err = f.Chmod(0600); err != nil {
		f.Close()
		return err
	}
	// Discard only an interrupted trailing event before appending. Each encoded
	// event is bounded below the minimum rotation limit, so a fixed-size tail
	// suffices without scanning the log.
	size := info.Size()
	if size > 0 {
		tailSize := int64(16384)
		if size < tailSize {
			tailSize = size
		}
		tail := make([]byte, int(tailSize))
		if _, err = f.ReadAt(tail, size-tailSize); err != nil {
			f.Close()
			return err
		}
		if tail[len(tail)-1] != '\n' {
			last := bytes.LastIndexByte(tail, '\n')
			if last < 0 {
				size = 0
			} else {
				size = size - tailSize + int64(last) + 1
			}
			if err = f.Truncate(size); err != nil {
				f.Close()
				return err
			}
		}
	}
	l.file, l.size = f, size
	return nil
}

func (l *accessLog) Write(b []byte) (int, error) {
	if int64(len(b)) > l.max {
		return 0, fmt.Errorf("access event exceeds log size limit")
	}
	if l.file == nil {
		if err := l.open(); err != nil {
			return 0, err
		}
	}
	if l.size+int64(len(b)) > l.max {
		if err := l.rotate(); err != nil {
			return 0, err
		}
	}
	boundary := l.size
	n, err := l.file.Write(b)
	if err == nil && n != len(b) {
		err = io.ErrShortWrite
	}
	if err != nil {
		// A failed event must not join the next JSON object or be rotated as a
		// retained line. If rollback fails, close it so open repairs the tail
		// before any subsequent write or rotation.
		if repairErr := l.file.Truncate(boundary); repairErr != nil {
			_ = l.file.Close()
			l.file = nil
		}
		return 0, err
	}
	l.size += int64(n)
	return n, nil
}

func (l *accessLog) rotate() error {
	l.file.Close()
	l.file = nil
	if l.files == 1 {
		if err := os.Remove(l.path); err != nil && !os.IsNotExist(err) {
			return err
		}
	} else {
		for i := l.files - 2; i >= 0; i-- {
			old := l.path
			if i != 0 {
				old = fmt.Sprintf("%s.%d", l.path, i)
			}
			if err := os.Rename(old, fmt.Sprintf("%s.%d", l.path, i+1)); err != nil && !os.IsNotExist(err) {
				return err
			}
		}
	}
	return l.open()
}

func (l *accessLog) Close() error {
	if l.file != nil {
		return l.file.Close()
	}
	return nil
}
