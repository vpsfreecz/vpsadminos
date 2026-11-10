package reposerver

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"math"
	"mime"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestDashboardConfiguredIdentity(t *testing.T) {
	s, _ := testStore(t)
	begin(t, s, "identity", "image")
	reader := NewStoreDashboardReader(s, "test", "identity", nil)
	for _, identity := range []struct{ name, purpose string }{
		{"Member images <custom>", "A purpose with <script>markup</script> & Unicode: obrazy"},
		{"", ""},
	} {
		h := NewHTTPHandler(s, HTTPOptions{Repository: "test", Instance: "identity", Dashboard: reader, DisplayName: identity.name, Purpose: identity.purpose})
		response := requestHTTP(h, "GET", "/dashboard/api/overview", nil)
		var got DashboardOverview
		if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &got) != nil {
			t.Fatal(response.Code, response.Body.String())
		}
		want := identity.name
		if want == "" {
			want = "test"
		}
		if got.DisplayName != want || got.Purpose != identity.purpose || got.Repository != "test" {
			t.Fatal(got)
		}
		if strings.Contains(response.Body.String(), "<script>") {
			t.Fatal("unescaped presentation text")
		}
		// The HTML path uses this same configured existing overview method.
		overview, err := h.(*repositoryHTTP).opts.Dashboard.DashboardOverview(context.Background())
		if err != nil || overview.DisplayName != got.DisplayName || overview.Purpose != got.Purpose {
			t.Fatal(overview, err)
		}
		original, err := reader.DashboardOverview(context.Background())
		if err != nil || original.DisplayName != "" || original.Purpose != "" {
			t.Fatal("configured identity leaked into shared reader", original, err)
		}
		legacy := requestHTTP(h, "GET", "/dashboard.json", nil)
		if legacy.Code != 200 || strings.Contains(legacy.Body.String(), `"display_name"`) || strings.Contains(legacy.Body.String(), `"purpose"`) {
			t.Fatal("legacy dashboard changed", legacy.Code, legacy.Body.String())
		}
	}
}

func TestDashboardUsageExtendedPeriodsUTC(t *testing.T) {
	s, clock := testStore(t)
	*clock = time.Date(2026, 11, 10, 0, 30, 0, 0, time.UTC)
	midnight := time.Date(2026, 11, 10, 0, 0, 0, 0, time.UTC)
	tuple := Tuple{Vendor: "vendor", Variant: "minimal", Arch: "x86_64", Distribution: "alpine", Version: "1"}
	var events []AccessEvent
	for _, when := range []time.Time{*clock, midnight.AddDate(0, 0, -89), midnight.AddDate(0, 0, -89).Add(-time.Nanosecond), midnight.AddDate(0, 0, -179), midnight.AddDate(0, 0, -179).Add(-time.Nanosecond)} {
		events = append(events, AccessEvent{Repository: "test", Instance: "periods", Timestamp: when, Scope: "public", Kind: "artifact", Tuple: &tuple, Method: "GET", Status: 200, Outcome: "complete", Bytes: 10})
	}
	if err := s.RecordHTTPBatch(context.Background(), events, 365, 100); err != nil {
		t.Fatal(err)
	}
	reader := NewStoreDashboardReader(s, "test", "periods", nil)
	for _, tc := range []struct {
		period string
		days   int
		count  int64
	}{{"90d", 90, 2}, {"180d", 180, 4}} {
		got, err := reader.DashboardUsage(context.Background(), UsageQuery{Period: tc.period})
		if err != nil || len(got.Days) != tc.days || !got.Start.Equal(midnight.AddDate(0, 0, -tc.days+1)) || !got.End.Equal(*clock) || got.Totals != (UsageCounters{FullDownloads: tc.count, TransferredBytes: tc.count * 10}) || got.Days[0].FullDownloads != 1 {
			t.Fatal(tc, got, err)
		}
		h := NewHTTPHandler(s, HTTPOptions{Repository: "test", Instance: "periods"})
		response := requestHTTP(h, "GET", "/dashboard/api/usage?period="+tc.period, nil)
		var api UsagePage
		if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &api) != nil || api.Totals != got.Totals {
			t.Fatal(response.Code, response.Body.String())
		}
	}
}

func TestDashboardUsageSemanticsAndCoverage(t *testing.T) {
	s, clock := testStore(t)
	now := time.Date(2026, 11, 10, 0, 30, 0, 0, time.UTC)
	*clock = now
	tuple := Tuple{Vendor: "v", Variant: "minimal", Arch: "x86_64", Distribution: "alpine", Version: "3.24"}
	base := AccessEvent{Repository: "test", Instance: "usage", Timestamp: now, Scope: "public", Kind: "artifact", Tuple: &tuple, Format: "tar", Method: "GET", Status: 200, Bytes: 10, Outcome: "complete", ClientIP: "private-address", UserAgent: "private-agent", Path: "/private-path"}
	events := []AccessEvent{base}
	add := func(change func(*AccessEvent)) { e := base; change(&e); events = append(events, e) }
	add(func(e *AccessEvent) { e.Status = 206; e.Bytes = 3 })
	add(func(e *AccessEvent) { e.Status = 200; e.Outcome = "interrupted"; e.Bytes = 4 })
	add(func(e *AccessEvent) { e.Status = 404; e.Bytes = 99 })
	add(func(e *AccessEvent) { e.Method = "HEAD"; e.Bytes = 0 })
	add(func(e *AccessEvent) { e.Status = 304; e.Bytes = 0 })
	add(func(e *AccessEvent) { e.Scope = "run"; e.Bytes = 1000 })
	add(func(e *AccessEvent) { e.Kind = "index"; e.Bytes = 1000 })
	add(func(e *AccessEvent) { e.Timestamp = now.Add(-time.Hour) })
	add(func(e *AccessEvent) { e.Timestamp = now.AddDate(0, 0, -200) })
	if err := s.RecordHTTPBatch(context.Background(), events, 365, 100); err != nil {
		t.Fatal(err)
	}
	reader := NewStoreDashboardReader(s, "test", "usage", nil)
	got, err := reader.DashboardUsage(context.Background(), UsageQuery{Period: "today"})
	if err != nil {
		t.Fatal(err)
	}
	if got.Totals != (UsageCounters{FullDownloads: 1, RangeRequests: 1, TransferredBytes: 17, InterruptedRequests: 1, ErrorRequests: 1}) {
		t.Fatal(got.Totals)
	}
	if len(got.Days) != 1 || got.Start.Hour() != 0 || got.End != now || got.Coverage.RetentionDays != 365 || got.Coverage.HistoryComplete || got.Coverage.RetainedFrom == nil {
		t.Fatal(got)
	}
	seven, err := reader.DashboardUsage(context.Background(), UsageQuery{})
	if err != nil || seven.Totals.FullDownloads != 2 || len(seven.Days) != 7 {
		t.Fatal(seven, err)
	}
	year, err := reader.DashboardUsage(context.Background(), UsageQuery{Period: "365d"})
	if err != nil || year.Totals.FullDownloads != 3 || len(year.Days) != 365 {
		t.Fatal(year, err)
	}
	legacy, err := s.HTTPStatistics(context.Background(), "test", "usage")
	var n, b int64
	for _, row := range legacy {
		n += row.Requests
		b += row.Bytes
	}
	var expectedBytes int64
	for _, e := range events {
		expectedBytes += e.Bytes
	}
	if err != nil || n != int64(len(events)) || b != expectedBytes {
		t.Fatal(n, b, legacy, err)
	}
	payload, _ := json.Marshal(year)
	for _, secret := range []string{"private-address", "private-agent", "private-path"} {
		if strings.Contains(string(payload), secret) {
			t.Fatal(string(payload))
		}
	}
	observer := &HTTPObserver{opts: ObserverOptions{StatsDays: 2}}
	short := NewStoreDashboardReader(s, "test", "usage", observer)
	partial, err := short.DashboardUsage(context.Background(), UsageQuery{Period: "365d"})
	if err != nil || partial.Coverage.RetentionDays != 2 || partial.Coverage.HistoryComplete || partial.Totals.FullDownloads != 2 {
		t.Fatal(partial, err)
	}
}
func TestDashboardUsagePaginationRevisionAndFilters(t *testing.T) {
	s, clock := testStore(t)
	*clock = time.Date(2026, 11, 10, 12, 0, 0, 0, time.UTC)
	events := []AccessEvent{}
	for _, name := range []string{"alpine", "debian", "fedora"} {
		for i := 0; i < 2; i++ {
			tuple := Tuple{Vendor: "v", Variant: "minimal", Arch: "x86_64", Distribution: name, Version: "1"}
			events = append(events, AccessEvent{Repository: "test", Instance: "page", Timestamp: *clock, Scope: "public", Kind: "artifact", Method: "GET", Status: 200, Bytes: 1, Outcome: "complete", Tuple: &tuple})
		}
	}
	if err := s.RecordHTTPBatch(context.Background(), events, 365, 100); err != nil {
		t.Fatal(err)
	}
	r := NewStoreDashboardReader(s, "test", "page", nil)
	q := UsageQuery{Limit: 1}
	first, err := r.DashboardUsage(context.Background(), q)
	if err != nil || len(first.Rows) != 1 || first.Rows[0].Distribution != "alpine" || first.Totals.FullDownloads != 6 || first.NextCursor == "" {
		t.Fatal(first, err)
	}
	q.Cursor = first.NextCursor
	second, err := r.DashboardUsage(context.Background(), q)
	if err != nil || second.Rows[0].Distribution != "debian" || second.Totals != first.Totals || !second.End.Equal(first.End) {
		t.Fatal(second, err)
	}
	q.Distribution = "fedora"
	if _, err = r.DashboardUsage(context.Background(), q); err == nil {
		t.Fatal("filter cursor accepted")
	}
	if err = s.RecordHTTP(context.Background(), events[0], 365, 100); err != nil {
		t.Fatal(err)
	}
	q.Distribution = ""
	if unchanged, e := r.DashboardUsage(context.Background(), q); e != nil || unchanged.Totals != first.Totals {
		t.Fatal(unchanged, e)
	}
	*clock = clock.Add(2 * time.Minute)
	if _, err = r.DashboardUsage(context.Background(), q); err == nil || !strings.HasPrefix(err.Error(), "conflict:") {
		t.Fatal("expired snapshot accepted", err)
	}
	for _, q := range []UsageQuery{{Period: "hour"}, {GroupBy: "SQL"}, {Limit: 101}, {Distribution: "../private"}, {Cursor: "!"}} {
		if _, err = r.DashboardUsage(context.Background(), q); err == nil {
			t.Fatal(q)
		}
	}
}

func TestDashboardUsageTotalsFromDailyRows(t *testing.T) {
	s, clock := testStore(t)
	*clock = time.Date(2026, 11, 10, 12, 0, 0, 0, time.UTC)
	tuple := Tuple{Vendor: "v", Variant: "minimal", Arch: "x86_64", Distribution: "alpine", Version: "1"}
	base := AccessEvent{Repository: "test", Instance: "daily", Timestamp: *clock, Scope: "public", Kind: "artifact", Tuple: &tuple, Method: "GET", Status: 200, Bytes: 10, Outcome: "complete"}
	second := tuple
	second.Version = "2"
	ranged := base
	ranged.Tuple, ranged.Timestamp, ranged.Status, ranged.Bytes = &second, clock.AddDate(0, 0, -1), 206, 3
	interrupted := ranged
	interrupted.Timestamp, interrupted.Status, interrupted.Bytes, interrupted.Outcome = clock.AddDate(0, 0, -2), 200, 4, "interrupted"
	failed := interrupted
	failed.Status, failed.Bytes, failed.Outcome = 500, 99, "complete"
	other := tuple
	other.Vendor = "other"
	excluded := base
	excluded.Tuple, excluded.Bytes = &other, 1000
	if err := s.RecordHTTPBatch(context.Background(), []AccessEvent{base, ranged, interrupted, failed, excluded}, 365, 100); err != nil {
		t.Fatal(err)
	}
	r := NewStoreDashboardReader(s, "test", "daily", nil)
	q := UsageQuery{Period: "7d", GroupBy: "image", Distribution: "alpine", Arch: "x86_64", Vendor: "v", Variant: "minimal", Limit: 1}
	page, err := r.DashboardUsage(context.Background(), q)
	want := UsageCounters{FullDownloads: 1, RangeRequests: 1, TransferredBytes: 17, InterruptedRequests: 1, ErrorRequests: 1}
	if err != nil || page.Totals != want || len(page.Rows) != 1 || page.NextCursor == "" || len(page.Days) != 7 {
		t.Fatal(page, err)
	}
	q.Cursor = page.NextCursor
	next, err := r.DashboardUsage(context.Background(), q)
	if err != nil || next.Totals != want || len(next.Rows) != 1 || next.Rows[0].Version == page.Rows[0].Version {
		t.Fatal(next, err)
	}
	q.Cursor, q.Period = "", "today"
	today, err := r.DashboardUsage(context.Background(), q)
	if err != nil || today.Totals != (UsageCounters{FullDownloads: 1, TransferredBytes: 10}) {
		t.Fatal(today, err)
	}
	q.Period, q.Version = "7d", "absent"
	empty, err := r.DashboardUsage(context.Background(), q)
	if err != nil || empty.Totals != (UsageCounters{}) || len(empty.Rows) != 0 || len(empty.Days) != 7 {
		t.Fatal(empty, err)
	}
}

func TestDashboardUsageTotalsSignedLimits(t *testing.T) {
	for _, metric := range []struct {
		name, outcome string
		status        int
		bytes         bool
	}{
		{"full", "complete", 200, false},
		{"range", "complete", 206, false},
		{"bytes", "complete", 200, true},
		{"interrupted", "interrupted", 200, false},
		{"error", "complete", 500, false},
	} {
		for _, values := range []struct {
			name        string
			first, last int64
		}{
			{"max", math.MaxInt64 - 1, 1},
			{"min", math.MinInt64 + 1, -1},
			{"negative", -2, 1},
			{"positive-overflow", math.MaxInt64, 1},
			{"negative-overflow", math.MinInt64, -1},
		} {
			t.Run(metric.name+"/"+values.name, func(t *testing.T) {
				s, clock := testStore(t)
				*clock = time.Date(2026, 11, 10, 12, 0, 0, 0, time.UTC)
				for i, value := range []int64{values.first, values.last} {
					requests, bytes := value, int64(0)
					if metric.bytes {
						requests, bytes = 0, value
					}
					// Separate days and groups isolate the full-selection total.
					// Persisted negative values must retain signed SUM semantics.
					_, err := s.db.Exec(`INSERT INTO http_daily(repository,instance,day,dimensions,requests,bytes,scope,kind,distribution,method,outcome,status) VALUES('test','limits',?,'{}',?,?,'public','artifact',?,'GET',?,?)`, clock.AddDate(0, 0, i-1).Format("2006-01-02"), requests, bytes, []string{"alpine", "debian"}[i], metric.outcome, metric.status)
					if err != nil {
						t.Fatal(err)
					}
				}
				var expected UsageCounters
				oldErr := s.db.QueryRow("SELECT " + usageSums + " FROM http_daily WHERE repository='test' AND instance='limits'").Scan(counterArgs(&expected)...)
				got, err := NewStoreDashboardReader(s, "test", "limits", nil).DashboardUsage(context.Background(), UsageQuery{})
				if oldErr != nil {
					if !strings.Contains(oldErr.Error(), "integer overflow") || err == nil || !strings.Contains(err.Error(), "integer overflow") {
						t.Fatal("SUM error changed", oldErr, err)
					}
				} else if err != nil || got.Totals != expected {
					t.Fatal(got.Totals, expected, err)
				}
			})
		}
	}
}

func TestDashboardHierarchyPagesAndGenerationInvalidation(t *testing.T) {
	s, _ := testStore(t)
	run := begin(t, s, "catalog", "one", "two")
	uploadItem(t, s, run.Key, "one", "12", "one")
	uploadItem(t, s, run.Key, "two", "13", "two")
	call(t, s, "producer", "finish", run.Key, map[string]any{}, "")
	publish(t, s, run.Key, "one", "two")
	r := NewStoreDashboardReader(s, "test", "one", nil)
	q := CatalogQuery{GroupBy: "version", Distribution: "debian", Arch: "x86_64", Vendor: "vendor", Variant: "minimal", Limit: 1}
	first, err := r.DashboardCatalog(context.Background(), q)
	if err != nil || len(first.Rows) != 1 || first.Rows[0].Version != "12" || len(first.Rows[0].Downloads) != 1 || first.NextCursor == "" {
		t.Fatal(first, err)
	}
	q.Cursor = first.NextCursor
	second, err := r.DashboardCatalog(context.Background(), q)
	if err != nil || second.Rows[0].Version != "13" {
		t.Fatal(second, err)
	}
	next := begin(t, s, "new", "three")
	uploadItem(t, s, next.Key, "three", "14", "three")
	call(t, s, "producer", "finish", next.Key, map[string]any{}, "")
	publish(t, s, next.Key, "three")
	if _, err = r.DashboardCatalog(context.Background(), q); err == nil || !strings.HasPrefix(err.Error(), "conflict:") {
		t.Fatal(err)
	}
	for _, bad := range []CatalogQuery{{Arch: "x86_64"}, {GroupBy: "arch"}, {GroupBy: "variant", Distribution: "debian"}, {GroupBy: "version", Distribution: "debian", Arch: "x86_64"}, {GroupBy: "nope"}, {Cursor: "!"}} {
		if _, err = r.DashboardCatalog(context.Background(), bad); err == nil {
			t.Fatal(bad)
		}
	}
	empty, err := r.DashboardCatalog(context.Background(), CatalogQuery{GroupBy: "arch", Distribution: "absent"})
	if err != nil || len(empty.Rows) != 0 {
		t.Fatal(empty, err)
	}
	overview, err := r.DashboardOverview(context.Background())
	if err != nil || overview.ImageVersions != 3 || overview.StorageFiles != 3 || overview.RunStates["finished"] != 2 {
		t.Fatal(overview, err)
	}
	a, err := s.catalogSnapshot(context.Background(), "test", "")
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.catalogSnapshot(context.Background(), "test", "")
	if err != nil || &a.index[0] != &b.index[0] {
		t.Fatal("cache not reused", err)
	}
}
func TestDashboardHTTPQueryErrorsHeadAndPrivacy(t *testing.T) {
	s, _ := testStore(t)
	begin(t, s, "api", "one")
	h := NewHTTPHandler(s, HTTPOptions{Repository: "test", Instance: "one"})
	for _, p := range []string{"/dashboard/api/usage", "/dashboard/api/catalog", "/dashboard/api/overview"} {
		got := requestHTTP(h, "GET", p, nil)
		if got.Code != 200 || !strings.Contains(got.Body.String(), "api_version") {
			t.Fatal(p, got.Code, got.Body.String())
		}
		head := requestHTTP(h, "HEAD", p, nil)
		if head.Code != 200 || head.Body.Len() != 0 {
			t.Fatal(head)
		}
	}
	for _, p := range []string{"/dashboard/api/usage?unknown=secret", "/dashboard/api/usage?limit=0", "/dashboard/api/usage?period=7d&period=30d", "/dashboard/api/catalog?version=1", "/dashboard/api/overview?limit=1", "/dashboard/api/usage?cursor=!"} {
		if got := requestHTTP(h, http.MethodGet, p, nil); got.Code != 400 {
			t.Fatal(p, got.Code, got.Body.String())
		}
	}
	s.reads.Close()
	if got := requestHTTP(h, "GET", "/dashboard/api/usage", nil); got.Code != 503 || strings.Contains(got.Body.String(), "sqlite") {
		t.Fatal(got.Code, got.Body.String())
	}
}
func TestObserverHealthyBatchedCountersAndLogFailure(t *testing.T) {
	s, _ := testStore(t)
	opts := ObserverOptions{Repository: "test", Instance: "batch", AccessLog: t.TempDir() + "/private/log", QueueSize: 1024, StatsDays: 365, StatsMaxRows: 100, LogFiles: 2, LogMaxBytes: 16384}
	o, err := NewHTTPObserver(s, opts)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 300; i++ {
		o.Observe(AccessEvent{Repository: "test", Instance: "batch", Timestamp: s.now(), Method: "GET", Status: 200, Kind: "artifact", Scope: "public", Outcome: "complete", Bytes: 3})
	}
	if err = o.Close(context.Background()); err != nil {
		t.Fatal(err)
	}
	if o.Health() != (MeasurementHealth{}) {
		t.Fatal(o.Health())
	}
	rows, err := s.HTTPStatistics(context.Background(), "test", "batch")
	if err != nil || len(rows) != 1 || rows[0].Requests != 300 || rows[0].Bytes != 900 {
		t.Fatal(rows, err)
	}

	blocker := filepath.Join(t.TempDir(), "file")
	if err = os.WriteFile(blocker, []byte("not a directory"), 0600); err != nil {
		t.Fatal(err)
	}
	opts.AccessLog = filepath.Join(blocker, "log")
	failedLog, err := NewHTTPObserver(s, opts)
	if err != nil {
		t.Fatal(err)
	}
	failedLog.Observe(AccessEvent{Repository: "test", Instance: "batch", Timestamp: s.now(), Method: "GET", Status: 200, Kind: "artifact", Scope: "public", Outcome: "complete", Bytes: 3})
	if err = failedLog.Close(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := failedLog.Health(); got.LogFailures != 1 || got.StatsFailures != 0 || got.Dropped != 0 {
		t.Fatal(got)
	}
	rows, err = s.HTTPStatistics(context.Background(), "test", "batch")
	if err != nil || rows[0].Requests != 301 || rows[0].Bytes != 903 {
		t.Fatal(rows, err)
	}
}

func TestCachedCatalogLeaseAndNativeCompatibility(t *testing.T) {
	s, now := testStore(t)
	r := begin(t, s, "cached", "one")
	uploadItem(t, s, r.Key, "one", "13", "pinned")
	call(t, s, "producer", "finish", r.Key, map[string]any{}, "")
	call(t, s, "producer", "seal", r.Key, map[string]any{}, "")
	publish(t, s, r.Key, "one")
	view, err := s.Catalog(context.Background(), "test", "")
	if err != nil {
		t.Fatal(err)
	}
	expected, err := nativeIndex(view.Catalog)
	if err != nil {
		t.Fatal(err)
	}
	h := NewHTTPHandler(s, HTTPOptions{Repository: "test", Instance: "cache"})
	first := requestHTTP(h, "GET", "/v1/INDEX.json", nil)
	if first.Code != 200 || first.Body.String() != string(expected) {
		t.Fatal(first.Code, first.Body.String())
	}
	runIndex := requestHTTP(h, "GET", "/runs/"+r.Key+"/v1/INDEX.json", nil)
	if runIndex.Code != 200 {
		t.Fatal(runIndex.Code)
	}
	*now = now.Add(11 * time.Minute)
	expired := requestHTTP(h, "GET", "/runs/"+r.Key+"/v1/INDEX.json", nil)
	if expired.Code != 410 {
		t.Fatal("cache authorized expired run", expired.Code)
	}
	public := requestHTTP(h, "GET", "/v1/INDEX.json", nil)
	if public.Code != 200 || public.Header().Get("ETag") != first.Header().Get("ETag") {
		t.Fatal(public.Code, public.Header())
	}
	if s.reads.Stats().MaxOpenConnections != 2 {
		t.Fatal(s.reads.Stats())
	}
}

func TestUsageHTTPPaginationSurvivesItsOwnMeasurement(t *testing.T) {
	s, clock := testStore(t)
	*clock = time.Date(2026, 11, 10, 12, 0, 0, 0, time.UTC)
	begin(t, s, "usage-http", "image")
	events := []AccessEvent{}
	for _, name := range []string{"alpine", "debian", "fedora"} {
		tuple := Tuple{Vendor: "vendor", Variant: "minimal", Arch: "x86_64", Distribution: name, Version: "1"}
		events = append(events, AccessEvent{Repository: "test", Instance: "pagination", Timestamp: *clock, Scope: "public", Kind: "artifact", Method: "GET", Status: 200, Outcome: "complete", Bytes: 7, Tuple: &tuple})
	}
	if err := s.RecordHTTPBatch(context.Background(), events, 365, 100); err != nil {
		t.Fatal(err)
	}
	opts := ObserverOptions{Repository: "test", Instance: "pagination", AccessLog: filepath.Join(t.TempDir(), "private", "access.jsonl"), QueueSize: 32, StatsDays: 365, StatsMaxRows: 100, LogFiles: 2, LogMaxBytes: 16384}
	observer := func() *HTTPObserver {
		o, err := NewHTTPObserver(s, opts)
		if err != nil {
			t.Fatal(err)
		}
		return o
	}
	drain := func(o *HTTPObserver) {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		if err := o.Close(ctx); err != nil {
			t.Fatal(err)
		}
		if o.Health() != (MeasurementHealth{}) {
			t.Fatal(o.Health())
		}
	}
	firstObserver := observer()
	dashboard := NewStoreDashboardReader(s, "test", "pagination", nil)
	h := NewHTTPHandler(s, HTTPOptions{Repository: "test", Instance: "pagination", Observer: firstObserver, Dashboard: dashboard})
	first := requestHTTP(h, "GET", "/dashboard/api/usage?limit=1", nil)
	var page UsagePage
	if first.Code != 200 || json.Unmarshal(first.Body.Bytes(), &page) != nil || page.NextCursor == "" {
		t.Fatal(first.Code, first.Body.String())
	}
	for _, path := range []string{"/dashboard/api/overview", "/v1/INDEX.json"} {
		response := requestHTTP(h, "GET", path, nil)
		if response.Code != 200 {
			t.Fatal(path, response.Code)
		}
	}
	// UI assets are also legacy accounting, not public image usage. Enqueue
	// their observation without depending on the later optional UI route.
	firstObserver.Observe(AccessEvent{Repository: "test", Instance: "pagination", Timestamp: *clock, Scope: "public", Kind: "asset", Method: "GET", Status: 200, Outcome: "complete", Bytes: 7})
	runEvent := events[0]
	runEvent.Scope = "run"
	firstObserver.Observe(runEvent)
	drain(firstObserver)
	secondObserver := observer()
	h = NewHTTPHandler(s, HTTPOptions{Repository: "test", Instance: "pagination", Observer: secondObserver, Dashboard: dashboard})
	second := requestHTTP(h, "GET", "/dashboard/api/usage?limit=1&cursor="+page.NextCursor, nil)
	var next UsagePage
	if second.Code != 200 || json.Unmarshal(second.Body.Bytes(), &next) != nil || len(next.Rows) != 1 || next.Rows[0].Distribution != "debian" || next.Totals != page.Totals || !next.End.Equal(page.End) {
		t.Fatal(second.Code, second.Body.String())
	}
	drain(secondObserver)
	legacy, err := s.HTTPStatistics(context.Background(), "test", "pagination")
	var requests int64
	for _, row := range legacy {
		requests += row.Requests
	}
	if err != nil || requests != 9 {
		t.Fatal(requests, legacy, err)
	}
	actual := observer()
	actual.Observe(events[0])
	drain(actual)
	h = NewHTTPHandler(s, HTTPOptions{Repository: "test", Instance: "pagination", Dashboard: dashboard})
	if got := requestHTTP(h, "GET", "/dashboard/api/usage?limit=1&cursor="+page.NextCursor, nil); got.Code != 200 {
		t.Fatal("usage update invalidated retained snapshot", got.Code, got.Body.String())
	}
	fresh := requestHTTP(h, "GET", "/dashboard/api/usage?limit=1", nil)
	if fresh.Code != 200 || json.Unmarshal(fresh.Body.Bytes(), &page) != nil {
		t.Fatal(fresh.Code)
	}
	index := events[0]
	index.Kind = "index"
	if err = s.RecordHTTP(context.Background(), index, 30, 100); err != nil {
		t.Fatal(err)
	}
	if got := requestHTTP(h, "GET", "/dashboard/api/usage?limit=1&cursor="+page.NextCursor, nil); got.Code != 409 {
		t.Fatal("retention change did not invalidate", got.Code)
	}
}

func TestUsageMultipartRangeCountsResponseBodyBytes(t *testing.T) {
	// Go 1.24 module compatibility defaults to one range. Exercise the
	// supported native multipart path without changing production defaults.
	t.Setenv("GODEBUG", os.Getenv("GODEBUG")+",httpservecontentmaxranges=2")
	s, clock := testStore(t)
	*clock = time.Now().UTC()
	fixture := newFixtureReader(t)

	opts := ObserverOptions{Repository: "repo", Instance: "multipart", AccessLog: filepath.Join(t.TempDir(), "private", "access.jsonl"), QueueSize: 8, StatsDays: 365, StatsMaxRows: 100, LogFiles: 2, LogMaxBytes: 16384}
	observer, err := NewHTTPObserver(s, opts)
	if err != nil {
		t.Fatal(err)
	}
	handler := NewHTTPHandler(fixture, HTTPOptions{Repository: "repo", Instance: "multipart", Observer: observer})
	response := requestHTTP(handler, "GET", "/v1/vendor/minimal/x86_64/debian/13/image-archive.tar", map[string]string{"Range": "bytes=0-0,2-2"})
	if response.Code != 206 {
		t.Fatal(response.Code, response.Header())
	}

	kind, params, err := mime.ParseMediaType(response.Header().Get("Content-Type"))
	if err != nil || kind != "multipart/byteranges" {
		t.Fatal(kind, err)
	}
	reader := multipart.NewReader(bytes.NewReader(response.Body.Bytes()), params["boundary"])
	for i, want := range []string{"p", "y"} {
		part, err := reader.NextPart()
		if err != nil {
			t.Fatal(err)
		}
		data, err := io.ReadAll(part)
		if err != nil || string(data) != want {
			t.Fatal(i, string(data), err)
		}
	}
	if _, err = reader.NextPart(); err != io.EOF {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err = observer.Close(ctx); err != nil {
		t.Fatal(err)
	}
	if observer.Health() != (MeasurementHealth{}) {
		t.Fatal(observer.Health())
	}
	raw, err := os.ReadFile(opts.AccessLog)
	if err != nil {
		t.Fatal(err)
	}
	var event AccessEvent
	if err = json.Unmarshal(raw, &event); err != nil {
		t.Fatal(err)
	}
	// Multipart framing belongs to the HTTP response body: preserve the legacy
	// count and use that same truthful metric, not a payload-only claim.
	written := int64(response.Body.Len())
	if written <= 2 || event.Bytes != written {
		t.Fatal(written, event.Bytes)
	}
	legacy, err := s.HTTPStatistics(ctx, "repo", "multipart")
	if err != nil || len(legacy) != 1 || legacy[0].Bytes != written {
		t.Fatal(legacy, err)
	}
	usage, err := NewStoreDashboardReader(s, "repo", "multipart", nil).DashboardUsage(ctx, UsageQuery{Period: "today"})
	if err != nil || usage.Totals.TransferredBytes != written || usage.Totals.RangeRequests != 1 || usage.Totals.FullDownloads != 0 {
		t.Fatal(usage.Totals, err)
	}
}
