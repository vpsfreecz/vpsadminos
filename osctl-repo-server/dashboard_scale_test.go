package reposerver

import (
	"context"
	"fmt"
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
