package reposerver

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"
)

func usageSnapshotFixture(t *testing.T) (*Store, *time.Time, *StoreDashboardReader, AccessEvent) {
	t.Helper()
	s, clock := testStore(t)
	*clock = time.Date(2026, 11, 10, 12, 0, 0, 0, time.UTC)
	var events []AccessEvent
	for _, name := range []string{"alpine", "debian", "fedora"} {
		tuple := Tuple{Distribution: name, Arch: "x86_64", Vendor: "vendor", Variant: "minimal", Version: "historical"}
		events = append(events, AccessEvent{Repository: "test", Instance: "snapshots", Timestamp: *clock, Scope: "public", Kind: "artifact", Tuple: &tuple, Method: "GET", Status: 200, Outcome: "complete", Bytes: 7})
	}
	if err := s.RecordHTTPBatch(context.Background(), events, 365, 100); err != nil {
		t.Fatal(err)
	}
	return s, clock, NewStoreDashboardReader(s, "test", "snapshots", nil), events[0]
}

func TestUsageSnapshotStableDuringTrafficAndRefresh(t *testing.T) {
	s, clock, reader, event := usageSnapshotFixture(t)
	q := UsageQuery{Limit: 1}
	first, err := reader.DashboardUsage(context.Background(), q)
	if err != nil || first.NextCursor == "" || first.Totals.FullDownloads != 3 {
		t.Fatal(first, err)
	}
	opts := ObserverOptions{Repository: "test", Instance: "snapshots", AccessLog: t.TempDir() + "/private/events", QueueSize: 32, StatsDays: 365, StatsMaxRows: 100, LogFiles: 2, LogMaxBytes: 16384}
	observer, err := NewHTTPObserver(s, opts)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 12; i++ {
		observer.Observe(event)
	}
	if err = observer.Close(context.Background()); err != nil || observer.Health() != (MeasurementHealth{}) {
		t.Fatal(err, observer.Health())
	}
	warm, err := reader.DashboardUsage(context.Background(), q)
	if err != nil || warm.NextCursor != first.NextCursor || warm.Totals != first.Totals {
		t.Fatal(warm, err)
	}
	*clock = clock.Add(31 * time.Second)
	fresh, err := reader.DashboardUsage(context.Background(), q)
	if err != nil || fresh.Totals.FullDownloads != 15 || fresh.NextCursor == first.NextCursor {
		t.Fatal(fresh, err)
	}
	q.Cursor = first.NextCursor
	next, err := reader.DashboardUsage(context.Background(), q)
	if err != nil || next.Totals != first.Totals || !next.End.Equal(first.End) || next.Rows[0].Distribution != "debian" {
		t.Fatal(next, err)
	}
	if len(reader.usage.entries) != 2 {
		t.Fatal("refresh destroyed retained cursor", len(reader.usage.entries))
	}
}

func TestUsageSnapshotHitsDoNotReaggregateAndAreImmutable(t *testing.T) {
	s, clock, reader, _ := usageSnapshotFixture(t)
	q := UsageQuery{Limit: 1}
	first, err := reader.DashboardUsage(context.Background(), q)
	if err != nil {
		t.Fatal(err)
	}
	cursor := first.NextCursor
	first.Rows[0].Distribution = "modified"
	first.Days[0].FullDownloads = 999
	*first.UpdatedAt = time.Time{}
	*first.Coverage.RetainedFrom = time.Time{}
	// Any attempt to aggregate/scan history now fails. Cheap policy lookup
	// remains possible and cached results must still serve first/next pages.
	if _, err = s.db.Exec("DROP TABLE http_daily"); err != nil {
		t.Fatal(err)
	}
	warm, err := reader.DashboardUsage(context.Background(), q)
	if err != nil || warm.Rows[0].Distribution != "alpine" || warm.Days[0].FullDownloads == 999 || warm.UpdatedAt.IsZero() || warm.Coverage.RetainedFrom.IsZero() {
		t.Fatal(warm, err)
	}
	q.Cursor = cursor
	if next, err := reader.DashboardUsage(context.Background(), q); err != nil || next.Rows[0].Distribution != "debian" {
		t.Fatal(next, err)
	}
	*clock = clock.Add(31 * time.Second)
	q.Cursor = ""
	if _, err = reader.DashboardUsage(context.Background(), q); err == nil {
		t.Fatal("cold refresh skipped missing history")
	}
}

func TestUsageSnapshotExpiryDayRetentionAndEviction(t *testing.T) {
	for _, reason := range []string{"expiry", "day", "retention", "eviction"} {
		t.Run(reason, func(t *testing.T) {
			s, clock, reader, event := usageSnapshotFixture(t)
			q := UsageQuery{Limit: 1}
			first, err := reader.DashboardUsage(context.Background(), q)
			if err != nil {
				t.Fatal(err)
			}
			switch reason {
			case "expiry":
				*clock = clock.Add(2 * time.Minute)
			case "day":
				*clock = clock.Add(24 * time.Hour)
			case "retention":
				event.Kind = "index"
				if err = s.RecordHTTP(context.Background(), event, 30, 100); err != nil {
					t.Fatal(err)
				}
			case "eviction":
				for _, period := range []string{"30d", "90d", "180d", "365d"} {
					if _, err = reader.DashboardUsage(context.Background(), UsageQuery{Period: period, Limit: 1}); err != nil {
						t.Fatal(err)
					}
				}
				if len(reader.usage.entries) != usageCacheMaxEntries {
					t.Fatal(len(reader.usage.entries))
				}
			}
			q.Cursor = first.NextCursor
			if _, err = reader.DashboardUsage(context.Background(), q); err == nil || !strings.HasPrefix(err.Error(), "conflict:") {
				t.Fatal(reason, err)
			}
		})
	}
}

func TestUsageSnapshotCoalescesAndCancelsAdmission(t *testing.T) {
	_, _, reader, _ := usageSnapshotFixture(t)
	const callers = 8
	start := make(chan struct{})
	results := make(chan UsagePage, callers)
	errorsFound := make(chan error, callers)
	var wg sync.WaitGroup
	for i := 0; i < callers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			page, err := reader.DashboardUsage(context.Background(), UsageQuery{Limit: 1})
			if err != nil {
				errorsFound <- err
				return
			}
			results <- page
		}()
	}
	close(start)
	wg.Wait()
	close(errorsFound)
	close(results)
	for err := range errorsFound {
		t.Fatal(err)
	}
	if len(reader.usage.entries) != 1 {
		t.Fatal("duplicate cold materialization", len(reader.usage.entries))
	}
	cursor := ""
	for page := range results {
		if cursor != "" && cursor != page.NextCursor {
			t.Fatal("callers did not share snapshot")
		}
		cursor = page.NextCursor
	}
	reader.usage.cold <- struct{}{}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	_, err := reader.DashboardUsage(ctx, UsageQuery{Period: "90d"})
	<-reader.usage.cold
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal("admission ignored context", err)
	}
	if _, err = reader.DashboardUsage(context.Background(), UsageQuery{Period: "90d"}); err != nil {
		t.Fatal("cancelled admission poisoned refresh", err)
	}
}

func TestUsageColdAdmissionLeavesWriterControlsAndStreamsProgressing(t *testing.T) {
	r, _, full, other := downloadFixture(t)
	reader := NewStoreDashboardReader(r.Store, "test", "progress", nil)
	reader.usage.cold = make(chan struct{}, 1)
	reader.usage.cold <- struct{}{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := reader.DashboardUsage(ctx, UsageQuery{Period: "365d"}); done <- err }()
	downloadProgress(t, "batched indexed counter write", func(ctx context.Context) error {
		tuple := Tuple{Vendor: "vendor", Variant: "minimal", Arch: "x86_64", Distribution: "debian", Version: "13"}
		event := AccessEvent{Repository: "test", Instance: "progress", Timestamp: r.now(), Scope: "public", Kind: "artifact", Method: "GET", Status: 200, Outcome: "complete", Bytes: 7, Tuple: &tuple}
		events := make([]AccessEvent, 128)
		for i := range events {
			events[i] = event
		}
		return r.RecordHTTPBatch(ctx, events, 365, 100)
	})
	downloadProgress(t, "short control during cold admission", func(ctx context.Context) error {
		response := r.Execute(ctx, "producer", Request{RequestID: id(), Operation: "status", Repository: "test", Params: encode(map[string]any{})}, nil)
		if !response.OK {
			return response.Error
		}
		return nil
	})
	h := NewHTTPHandler(r, HTTPOptions{Repository: "test"})
	for _, path := range []string{"/v1/INDEX.json", "/v1/vendor/minimal/x86_64/debian/13/image-archive.tar", "/v1/vendor/minimal/x86_64/debian/14/image-archive.tar"} {
		downloadProgress(t, path, func(ctx context.Context) error {
			headers := map[string]string{}
			if strings.Contains(path, "/14/") {
				headers["Range"] = "bytes=0-1023"
			}
			response := requestHTTP(h, "GET", path, headers)
			if strings.Contains(path, "/13/") {
				downloadBytes(t, response.Body.Bytes(), full)
			}
			if strings.Contains(path, "/14/") {
				downloadBytes(t, response.Body.Bytes(), other[:1024])
			}
			if response.Code != 200 && response.Code != 206 {
				t.Fatal(response.Code)
			}
			return nil
		})
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("cold admission did not cancel promptly")
	}
	<-reader.usage.cold
	if r.reads.Stats().InUse != 0 {
		t.Fatal("admission held read connection")
	}
	page, err := reader.DashboardUsage(context.Background(), UsageQuery{})
	if err != nil || page.Totals.FullDownloads != 128 || page.Totals.TransferredBytes != 896 {
		t.Fatal(page.Totals, err)
	}
	if usageColdTimeout != 5*time.Second {
		t.Fatal("cold and admission budget changed", usageColdTimeout)
	}
}
