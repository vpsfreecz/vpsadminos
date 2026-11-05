package reposerver

import (
	"context"
	"testing"
	"time"
)

func TestHTTPAggregatePersistenceBoundsAndPrivacy(t *testing.T) {
	store, err := OpenStore(Options{Root: t.TempDir(), MaxBytes: 1048576, ReservedBytes: 1, MaxUploadBytes: 1024, MaxRuns: 4, MaxLease: time.Hour, ExportLease: time.Minute})
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	ctx := context.Background()
	now := time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)
	e := AccessEvent{Repository: "repo", Instance: "one", Timestamp: now, Scope: "public", Kind: "artifact", Method: "GET", Status: 200, Bytes: 7, Outcome: "complete", ClientIP: "192.0.2.55", UserAgent: "private-agent", Path: "/private-path"}
	if err := store.RecordHTTP(ctx, e, 2, 1); err != nil {
		t.Fatal(err)
	}
	e.ClientIP = "198.51.100.1"
	e.UserAgent = "other-agent"
	if err := store.RecordHTTP(ctx, e, 2, 1); err != nil {
		t.Fatal(err)
	}
	stats, err := store.HTTPStatistics(ctx, "repo", "one")
	if err != nil || len(stats) != 1 || stats[0].Requests != 2 || stats[0].Bytes != 14 {
		t.Fatal(stats, err)
	}
	e.Status = 206
	if err := store.RecordHTTP(ctx, e, 2, 1); err == nil {
		t.Fatal("unbounded dimensions accepted")
	}
	e.Timestamp = now.AddDate(0, 0, 3)
	if err := store.RecordHTTP(ctx, e, 2, 1); err != nil {
		t.Fatal(err)
	}
	stats, err = store.HTTPStatistics(ctx, "repo", "one")
	if err != nil || len(stats) != 1 || stats[0].Status != 206 || stats[0].Requests != 1 {
		t.Fatal(stats, err)
	}
	other, err := store.HTTPStatistics(ctx, "repo", "two")
	if err != nil || len(other) != 0 {
		t.Fatal(other, err)
	}
}
