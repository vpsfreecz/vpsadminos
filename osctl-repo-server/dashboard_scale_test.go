package reposerver

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// Prepared acceptance only. Run after committed independent review:
// go test -run '^$' -bench '^BenchmarkDashboardScale$' -benchtime=1x -count=1
// Ten thousand catalog tuples and one hundred thousand daily rows, no payload
// files, guests or listeners. The aggregate query itself has a 2-second bound.
func BenchmarkDashboardScale(b *testing.B) {
	now := time.Date(2026, 11, 10, 12, 0, 0, 0, time.UTC)
	options := legacyOptions(b.TempDir())
	options.Now = func() time.Time { return now }
	s, err := OpenStore(options)
	if err != nil {
		b.Fatal(err)
	}
	defer s.Close()
	tx, err := s.db.Begin()
	if err != nil {
		b.Fatal(err)
	}
	c := Catalog{Vendors: map[string]string{"default": "vendor", "vendor": "minimal"}, Images: []Image{}}
	for i := 0; i < 10000; i++ {
		im := Image{Tuple: Tuple{Vendor: "vendor", Variant: "minimal", Arch: "x86_64", Distribution: fmt.Sprintf("dist-%04d", i/10), Version: fmt.Sprintf("%d", i%10)}, Tags: []string{}, Files: map[string]FileRef{"tar": {ID: fmt.Sprintf("f-%d", i), SHA256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", Size: 1, Format: "tar", Modified: now}}}
		c.Images = append(c.Images, im)
	}
	if _, err = tx.Exec("INSERT INTO catalogs VALUES('scale','scale',?,?,0)", encode(c), timestamp(now)); err != nil {
		b.Fatal(err)
	}
	if _, err = tx.Exec("INSERT INTO repositories VALUES('scale','scale')"); err != nil {
		b.Fatal(err)
	}
	statement, err := tx.Prepare("INSERT INTO http_daily(repository,instance,day,dimensions,requests,bytes,scope,kind,distribution,arch,vendor,variant,version,format,method,outcome,status) VALUES('scale','one',?,?,1,7,'public','artifact',?,'x86_64','vendor','minimal',?,'tar','GET','complete',200)")
	if err != nil {
		b.Fatal(err)
	}
	for i := 0; i < 100000; i++ {
		im := c.Images[i%10000]
		day := now.AddDate(0, 0, -i/10000).Format("2006-01-02")
		dim := string(encode(AggregateKey{Scope: "public", Kind: "artifact", Tuple: im.Tuple, Format: "tar", Method: "GET", Status: 200, Outcome: "complete"}))
		if _, err = statement.Exec(day, dim, im.Distribution, im.Version); err != nil {
			b.Fatal(err)
		}
	}
	statement.Close()
	if _, err = tx.Exec("INSERT INTO http_measurement VALUES('scale','one',365,1,?)", timestamp(now)); err != nil {
		b.Fatal(err)
	}
	if err = tx.Commit(); err != nil {
		b.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	reader := NewStoreDashboardReader(s, "scale", "one", nil)
	start := time.Now()
	snapshot, err := s.catalogSnapshot(ctx, "scale", "")
	cold := time.Since(start)
	if err != nil {
		b.Fatal(err)
	}
	if cold > 2*time.Second {
		b.Fatalf("cold INDEX %s exceeds 2s", cold)
	}
	start = time.Now()
	warm, err := s.catalogSnapshot(ctx, "scale", "")
	if err != nil || len(warm.index) != len(snapshot.index) {
		b.Fatal(err)
	}
	if elapsed := time.Since(start); elapsed > 500*time.Millisecond {
		b.Fatalf("warm INDEX %s", elapsed)
	}
	start = time.Now()
	page, err := reader.DashboardCatalog(ctx, CatalogQuery{})
	if err != nil || len(page.Rows) > 100 {
		b.Fatal(err)
	}
	if elapsed := time.Since(start); elapsed > 500*time.Millisecond {
		b.Fatalf("catalog page %s", elapsed)
	}
	queryCtx, queryCancel := context.WithTimeout(ctx, 2*time.Second)
	defer queryCancel()
	start = time.Now()
	usage, err := reader.DashboardUsage(queryCtx, UsageQuery{Period: "365d"})
	if err != nil || usage.Totals.FullDownloads != 100000 || len(usage.Rows) > 100 {
		b.Fatalf("usage %+v: %v", usage.Totals, err)
	}
	if elapsed := time.Since(start); elapsed > 500*time.Millisecond {
		b.Fatalf("usage page %s", elapsed)
	}
	b.ReportMetric(float64(cold.Microseconds()), "cold-index-us")
	b.ReportMetric(float64(len(snapshot.index)), "index-bytes")
}

// Prepared only: the lead runs this after committed review. Every subcase uses
// one million unique daily keys across all 365 days, including unpublished tuples.
// go test -run '^$' -bench '^BenchmarkDashboardUsageDense365$' -benchtime=1x -count=1
func BenchmarkDashboardUsageDense365(b *testing.B) {
	for _, groupCount := range []int{10000, 100000, 1000000} {
		b.Run(fmt.Sprintf("groups-%d", groupCount), func(b *testing.B) {
			now := time.Date(2026, 11, 10, 12, 0, 0, 0, time.UTC)
			opts := legacyOptions(b.TempDir())
			opts.Now = func() time.Time { return now }
			s, err := OpenStore(opts)
			if err != nil {
				b.Fatal(err)
			}
			defer s.Close()
			tx, err := s.db.Begin()
			if err != nil {
				b.Fatal(err)
			}
			stmt, err := tx.Prepare(`INSERT INTO http_daily(repository,instance,day,dimensions,requests,bytes,scope,kind,distribution,arch,vendor,variant,version,format,method,outcome,status) VALUES('dense','one',?,?,?,?,'public','artifact',?,?,?,?,?,?,?, ?,?)`)
			if err != nil {
				b.Fatal(err)
			}
			// One independent oracle per persisted row is unnecessary. Keep only
			// per-day and per-image sums; no catalog is used to restrict history.
			imageTotals := map[Tuple]UsageCounters{}
			dayTotals := map[string]UsageCounters{}
			filteredDays := map[string]UsageCounters{}
			var expected UsageCounters
			add := func(a UsageCounters, c UsageCounters) UsageCounters {
				return UsageCounters{FullDownloads: a.FullDownloads + c.FullDownloads, RangeRequests: a.RangeRequests + c.RangeRequests, TransferredBytes: a.TransferredBytes + c.TransferredBytes, InterruptedRequests: a.InterruptedRequests + c.InterruptedRequests, ErrorRequests: a.ErrorRequests + c.ErrorRequests}
			}
			for i := 0; i < 1000000; i++ {
				group, sample := i%groupCount, i/groupCount
				tuple := Tuple{Distribution: fmt.Sprintf("dist-%04d", group/100), Arch: []string{"x86_64", "aarch64"}[group%2], Vendor: "vendor", Variant: "minimal", Version: fmt.Sprint(group % 100)}
				day := now.AddDate(0, 0, -(group*101+sample*37)%365).Format("2006-01-02")
				status, outcome, method := 200, "complete", "GET"
				switch (group + sample) % 8 {
				case 1:
					status = 206
				case 2:
					outcome = "interrupted"
				case 3:
					status = 404
				case 4:
					method = "HEAD"
				case 5:
					status = 500
				case 6:
					status, outcome = 206, "interrupted"
				case 7:
					status = 304
				}
				n, bytes := int64(i%5+1), int64(i%5+1)*int64(group%4096+100)
				format := []string{"tar", "zfs"}[(group+sample)%2]
				dim := string(encode(AggregateKey{Scope: "public", Kind: "artifact", Tuple: tuple, Format: format, Method: method, Status: status, Outcome: outcome}))
				if _, err = stmt.Exec(day, dim, n, bytes, tuple.Distribution, tuple.Arch, tuple.Vendor, tuple.Variant, tuple.Version, format, method, outcome, status); err != nil {
					b.Fatal(err)
				}
				counts := UsageCounters{}
				if method == "GET" && status == 200 && outcome == "complete" {
					counts.FullDownloads = n
				}
				if method == "GET" && status == 206 {
					counts.RangeRequests = n
				}
				if method == "GET" && (status == 200 || status == 206) {
					counts.TransferredBytes = bytes
				}
				if outcome == "interrupted" {
					counts.InterruptedRequests = n
				}
				if status >= 400 {
					counts.ErrorRequests = n
				}
				expected = add(expected, counts)
				dayTotals[day] = add(dayTotals[day], counts)
				if group == 0 {
					filteredDays[day] = add(filteredDays[day], counts)
				}
				if groupCount <= 100000 {
					imageTotals[tuple] = add(imageTotals[tuple], counts)
				}
			}
			stmt.Close()
			if _, err = tx.Exec("INSERT INTO http_measurement VALUES('dense','one',365,1,?)", timestamp(now)); err != nil {
				b.Fatal(err)
			}
			if err = tx.Commit(); err != nil {
				b.Fatal(err)
			}
			var rows, days int
			if err = s.db.QueryRow("SELECT count(*),count(DISTINCT day) FROM http_daily").Scan(&rows, &days); err != nil || rows != 1000000 || days != 365 {
				b.Fatal(rows, days, err)
			}
			queries := []UsageQuery{{Period: "365d", GroupBy: "distribution", Limit: 50}, {Period: "365d", GroupBy: "arch", Limit: 50}, {Period: "365d", GroupBy: "image", Limit: 50}, {Period: "365d", GroupBy: "image", Distribution: "dist-0000", Arch: "x86_64", Vendor: "vendor", Variant: "minimal", Version: "0", Limit: 50}}
			if groupCount == 1000000 {
				queries = queries[2:3]
			}
			for _, q := range queries {
				reader := NewStoreDashboardReader(s, "dense", "one", nil)
				start := time.Now()
				page, err := reader.DashboardUsage(context.Background(), q)
				elapsed := time.Since(start)
				boundaryImage := groupCount == 100000 && q.GroupBy == "image" && q.Distribution == ""
				if groupCount == 1000000 || boundaryImage && err != nil {
					if !acceptedUsageRefusal(err) {
						b.Fatalf("high-cardinality case returned an unexpected error: %v", err)
					}
					releaseStart := time.Now()
					for s.reads.Stats().InUse != 0 && time.Since(releaseStart) < 500*time.Millisecond {
						time.Sleep(time.Millisecond)
					}
					released := time.Since(releaseStart)
					if len(reader.usage.entries) != 0 || s.reads.Stats().InUse != 0 || len(reader.usage.cold) != 0 {
						b.Fatal("refused query retained partial cache/transaction/admission")
					}
					b.Logf("%d-group bounded refusal: cold=%s cancellation_overshoot=%s release=%s error=%v; no partial snapshot; latency refusal is not a memory claim", groupCount, elapsed, max(time.Duration(0), elapsed-usageColdTimeout), released, err)
					continue // The 100k exact-filter case MUST still complete below.
				}
				if err != nil || elapsed > usageColdTimeout {
					b.Fatalf("dense cold %s %+v: %v", elapsed, q, err)
				}
				if q.Distribution == "" {
					if page.Totals != expected || len(page.Days) != 365 {
						b.Fatal(page.Totals, expected)
					}
					for _, day := range page.Days {
						if day.UsageCounters != dayTotals[day.Day] {
							b.Fatal("daily oracle mismatch", day)
						}
					}
				}
				oracle := map[Tuple]UsageCounters{}
				var filtered UsageCounters
				for tuple, counts := range imageTotals {
					if q.Distribution != "" && (tuple.Distribution != q.Distribution || tuple.Arch != q.Arch || tuple.Vendor != q.Vendor || tuple.Variant != q.Variant || tuple.Version != q.Version) {
						continue
					}
					filtered = add(filtered, counts)
					key := tuple
					if q.GroupBy == "distribution" {
						key = Tuple{Distribution: tuple.Distribution}
					}
					if q.GroupBy == "arch" {
						key = Tuple{Distribution: tuple.Distribution, Arch: tuple.Arch}
					}
					oracle[key] = add(oracle[key], counts)
				}
				if page.Totals != filtered {
					b.Fatal("filtered total mismatch", page.Totals, filtered)
				}
				if q.Distribution != "" {
					for _, day := range page.Days {
						if day.UsageCounters != filteredDays[day.Day] {
							b.Fatal("filtered daily oracle mismatch", day)
						}
					}
				}
				snapshot := reader.usage.entries[0]
				if len(snapshot.page.Rows) != len(oracle) {
					b.Fatal("missing retained historical groups", len(snapshot.page.Rows), len(oracle))
				}
				for _, row := range snapshot.page.Rows {
					if row.UsageCounters != oracle[row.Tuple] {
						b.Fatal("group oracle mismatch", row)
					}
				}
				start = time.Now()
				warm, e := reader.DashboardUsage(context.Background(), q)
				if e != nil || time.Since(start) > 500*time.Millisecond || warm.Totals != page.Totals || len(reader.usage.entries) != 1 {
					b.Fatal("warm dense snapshot", e)
				}
				if page.NextCursor != "" {
					q.Cursor = page.NextCursor
					start = time.Now()
					next, e := reader.DashboardUsage(context.Background(), q)
					if e != nil || time.Since(start) > 500*time.Millisecond || next.Totals != page.Totals || len(reader.usage.entries) != 1 {
						b.Fatal("next dense snapshot", e)
					}
				}
				b.Logf("%d groups, %s filter=%s: cold=%s retained=%d bytes", groupCount, q.GroupBy, q.Distribution, elapsed, snapshot.bytes)
			}
			if groupCount == 10000 {
				// Measure real expression-index inserts and counter updates only
				// after unchanged dense selection/oracle gates have completed.
				events := make([]AccessEvent, 128)
				for i := range events {
					tuple := Tuple{Distribution: "write-cost", Arch: "x86_64", Vendor: "vendor", Variant: "minimal", Version: fmt.Sprint(i)}
					events[i] = AccessEvent{Repository: "dense", Instance: "write-cost", Timestamp: now, Scope: "public", Kind: "artifact", Tuple: &tuple, Method: "GET", Status: 200, Outcome: "complete", Bytes: 7}
				}
				writeCtx, writeCancel := context.WithTimeout(context.Background(), 5*time.Second)
				start := time.Now()
				for i := 0; i < 16; i++ {
					if err = s.RecordHTTPBatch(writeCtx, events, 365, 1000000); err != nil {
						b.Fatal(err)
					}
				}
				elapsed := time.Since(start)
				writeCancel()
				stats, e := s.HTTPStatistics(context.Background(), "dense", "write-cost")
				var requests, bytes int64
				for _, row := range stats {
					requests += row.Requests
					bytes += row.Bytes
				}
				if e != nil || requests != 2048 || bytes != 14336 {
					b.Fatal("indexed batch counters", requests, bytes, e)
				}
				var pages, free, pageSize int64
				if e = s.db.QueryRow("PRAGMA page_count").Scan(&pages); e != nil {
					b.Fatal(e)
				}
				if e = s.db.QueryRow("PRAGMA freelist_count").Scan(&free); e != nil {
					b.Fatal(e)
				}
				if e = s.db.QueryRow("PRAGMA page_size").Scan(&pageSize); e != nil {
					b.Fatal(e)
				}
				walBytes := int64(0)
				if info, e := os.Stat(filepath.Join(opts.Root, "catalog.sqlite-wal")); e == nil {
					walBytes = info.Size()
				} else if !os.IsNotExist(e) {
					b.Fatal(e)
				}
				b.Logf("expression index: 16 batches x128 distinct counters=%s, DBpages=%d freepages=%d pagesize=%d WALbytes=%d (fixture cost, not production throughput)", elapsed, pages, free, pageSize, walBytes)
			}
		})
	}
}

// A boundary never permits unrelated database failures or a matching error string.
func acceptedUsageRefusal(err error) bool {
	var failure *Error
	return !errors.Is(err, context.Canceled) && (errors.Is(err, context.DeadlineExceeded) || errors.As(err, &failure) && failure.Code == "bounded")
}
