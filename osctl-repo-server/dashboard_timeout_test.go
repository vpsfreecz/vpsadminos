package reposerver

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

type usageErrorReader struct {
	DashboardReader
	err error
}

func (r usageErrorReader) DashboardUsage(context.Context, UsageQuery) (UsagePage, error) {
	return UsagePage{}, r.err
}

func TestUsageDeadlineHTTPMapping(t *testing.T) {
	for _, tc := range []struct {
		name    string
		err     error
		timeout bool
	}{
		{"deadline", context.DeadlineExceeded, true},
		{"wrapped deadline", fmt.Errorf("query: %w", context.DeadlineExceeded), true},
		{"cancelled", context.Canceled, false},
		{"wrapped cancelled", fmt.Errorf("query: %w", context.Canceled), false},
		{"cancelled and deadline", errors.Join(context.Canceled, context.DeadlineExceeded), false},
		{"database", errors.New("private database path failure"), false},
		{"deadline text only", errors.New("context deadline exceeded"), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := NewHTTPHandler(newFixtureReader(t), HTTPOptions{Repository: "test", Dashboard: usageErrorReader{err: tc.err}})
			response := requestHTTP(h, "GET", "/dashboard/api/usage", nil)
			if response.Code != 503 || response.Header().Get("Cache-Control") != "no-store" {
				t.Fatal(response.Code, response.Header())
			}
			want := "Dashboard unavailable"
			if tc.timeout {
				want = "Usage took too long. Choose a shorter period or narrower filter, or try again later."
			}
			if response.Body.String() != want+"\n" {
				t.Fatal(response.Body.String())
			}
			if strings.Contains(response.Body.String(), "private") || strings.Contains(response.Body.String(), "context") {
				t.Fatal("internal error exposed")
			}
		})
	}
}

func TestUsageBoundaryAcceptsOnlyExplicitRefusal(t *testing.T) {
	for _, tc := range []struct {
		err  error
		want bool
	}{
		{context.DeadlineExceeded, true},
		{fmt.Errorf("wrapped: %w", context.DeadlineExceeded), true},
		{problem("bounded", "selection too large"), true},
		{fmt.Errorf("wrapped: %w", problem("bounded", "selection too large")), true},
		{nil, false}, {context.Canceled, false}, {errors.Join(context.Canceled, context.DeadlineExceeded), false}, {errors.New("context deadline exceeded"), false},
		{problem("integrity", "invalid stored content"), false}, {errors.New("database failed"), false},
	} {
		if got := acceptedUsageRefusal(tc.err); got != tc.want {
			t.Fatal(tc.err, got)
		}
	}
}

func TestUsageDeadlineLeavesNoSnapshotAndAllowsNarrowedSelection(t *testing.T) {
	s, _, reader, _ := usageSnapshotFixture(t)
	reader.usage.cold = make(chan struct{}, 1)
	reader.usage.cold <- struct{}{} // A different materializer owns admission.
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	start := time.Now()
	page, err := reader.DashboardUsage(ctx, UsageQuery{Period: "365d", GroupBy: "image"})
	elapsed := time.Since(start)
	if !errors.Is(err, context.DeadlineExceeded) || elapsed > 500*time.Millisecond || page.NextCursor != "" || len(page.Rows) != 0 || page.Totals != (UsageCounters{}) {
		t.Fatal(page, err, elapsed)
	}
	if len(reader.usage.entries) != 0 || s.reads.Stats().InUse != 0 {
		t.Fatal("deadline retained partial snapshot/connection")
	}
	if len(reader.usage.cold) != 1 {
		t.Fatal("waiting caller changed another materializer's admission")
	}
	<-reader.usage.cold
	filtered, err := reader.DashboardUsage(context.Background(), UsageQuery{Period: "365d", GroupBy: "image", Distribution: "alpine"})
	if err != nil || filtered.Totals.FullDownloads != 1 || len(filtered.Rows) != 1 || len(reader.usage.cold) != 0 {
		t.Fatal("narrowed recovery", filtered, err)
	}
}
