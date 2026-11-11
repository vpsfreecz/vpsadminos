package reposerver

import (
	"fmt"
	"math"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"
)

func graphUsageFixture(days int) UsagePage {
	end := time.Date(2026, 1, 3, 12, 34, 56, 0, time.UTC)
	start := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC).AddDate(0, 0, -days+1)
	usage := UsagePage{Start: start, End: end, Coverage: UsageCoverage{RetainedFrom: &start, RetentionDays: 365, HistoryComplete: true}}
	for i := 0; i < days; i++ {
		counters := UsageCounters{FullDownloads: int64(i + 1), TransferredBytes: int64(i+1) * 1024, RangeRequests: 999}
		usage.Days = append(usage.Days, UsageDay{Day: start.AddDate(0, 0, i).Format("2006-01-02"), UsageCounters: counters})
		if err := addUsageCounters(&usage.Totals, counters); err != nil {
			panic(err)
		}
	}
	return usage
}

func TestDashboardGraphsMetricsUTCAndBounds(t *testing.T) {
	for _, days := range []int{1, 7, 365} {
		t.Run(strconv.Itoa(days), func(t *testing.T) {
			u := graphUsageFixture(days)
			// Backend rows need not arrive in display order; the date defines X.
			u.Days[0], u.Days[days-1] = u.Days[days-1], u.Days[0]
			graphs, err := dashboardGraphs(u)
			if err != nil || len(graphs) != 2 {
				t.Fatal(graphs, err)
			}
			for m, g := range graphs {
				if len(g.Points) != days || g.Empty {
					t.Fatal("lost daily positions", g.ID)
				}
				for i, p := range g.Points {
					want := int64(i + 1)
					if m == 0 {
						want *= 1024
					}
					if !p.Known || p.Value != strconv.FormatInt(want, 10) || p.Day != u.Start.AddDate(0, 0, i).Format("2006-01-02") {
						t.Fatal("wrong metric or UTC date", p)
					}
					for _, v := range []string{p.X, p.Y, p.Width, p.Height} {
						n, e := strconv.ParseFloat(v, 64)
						if e != nil || math.IsNaN(n) || math.IsInf(n, 0) || n < 0 {
							t.Fatal("invalid SVG geometry", v)
						}
					}
				}
				if !strings.Contains(g.Points[days-1].Readout, "through 12:34:56 UTC") || !strings.Contains(g.Description, "Recorded total:") {
					t.Fatal("partial current day or accessible total lost")
				}
			}
			if days > 1 && !strings.Contains(graphs[0].Ticks[0], "202") {
				t.Fatal("year boundary lost year labels")
			}
		})
	}
}

func TestDashboardGraphsCoverageEmptyZeroAndLarge(t *testing.T) {
	u := graphUsageFixture(7)
	retained := u.Start.AddDate(0, 0, 2)
	u.Coverage.RetainedFrom, u.Coverage.RetentionDays, u.Coverage.HistoryComplete = &retained, 4, false
	u.Days[4].FullDownloads, u.Days[4].TransferredBytes = 0, 0
	graphs, err := dashboardGraphs(u)
	if err != nil {
		t.Fatal(err)
	}
	for _, g := range graphs {
		for i, p := range g.Points {
			if p.Known != (i >= 3 && i != 4) {
				t.Fatal("retention cutoff or incomplete zero fabricated", i, p)
			}
		}
		if !strings.Contains(g.Points[4].Readout, "No recorded value") {
			t.Fatal("missing value described as zero")
		}
	}
	u = graphUsageFixture(1)
	u.Coverage.RetainedFrom = nil
	graphs, _ = dashboardGraphs(u)
	if graphs[0].Empty || !graphs[0].Points[0].Known {
		t.Fatal("unknown start suppressed positive recorded counter")
	}
	u.Days[0].FullDownloads, u.Days[0].TransferredBytes = 0, 0
	graphs, _ = dashboardGraphs(u)
	if !graphs[0].Empty || !graphs[1].Empty {
		t.Fatal("unknown history turned into successful zero")
	}
	u.Coverage.RetainedFrom = &u.Start
	graphs, _ = dashboardGraphs(u)
	if graphs[0].Empty || graphs[0].Points[0].Value != "0" || graphs[0].Points[0].Height != "1.000" {
		t.Fatal("complete measured zero lost")
	}
	u.Days = nil
	graphs, _ = dashboardGraphs(u)
	if !graphs[0].Empty {
		t.Fatal("empty retained series fabricated a line")
	}
	u = graphUsageFixture(1)
	u.Days[0].FullDownloads, u.Days[0].TransferredBytes = math.MaxInt64, math.MaxInt64
	u.Totals = u.Days[0].UsageCounters
	graphs, err = dashboardGraphs(u)
	if err != nil || graphs[0].Points[0].Value != "9223372036854775807" || graphs[1].Points[0].Height != "180.000" {
		t.Fatal("int64 exact values or finite scaling lost", err)
	}
	for _, mutate := range []func(*UsagePage){
		func(p *UsagePage) { p.Days[0].FullDownloads = -1 },
		func(p *UsagePage) { p.Days[0].Day = "<script>bad</script>" },
		func(p *UsagePage) { p.Days[0].Day = "2025-12-01" },
		func(p *UsagePage) { p.Days = append(p.Days, p.Days[0]) },
		func(p *UsagePage) { p.End = p.Start.Add(-time.Hour) },
	} {
		p := graphUsageFixture(1)
		mutate(&p)
		if _, err := dashboardGraphs(p); err == nil {
			t.Fatal("malformed daily series coerced to success", p)
		}
	}
}

func TestDashboardGraphsRenderedSnapshotAndSparseCopy(t *testing.T) {
	f := &uiDashboardFixture{versions: 10000}
	purpose := "Exact purpose sentence with <escaped> text spanning the header."
	h := NewHTTPHandler(newFixtureReader(t), HTTPOptions{Dashboard: f, Purpose: purpose})
	var initial string
	for _, cursor := range []string{"", "next"} {
		q := url.Values{"period": {"365d"}, "usage_cursor": {cursor}}
		get := requestHTTP(h, "GET", "/usage?"+q.Encode(), nil)
		body := get.Body.String()
		if get.Code != 200 || strings.Count(body, `<figure class="daily-graph"`) != 2 || strings.Count(body, "data-day=") != 730 || len(body) > 256<<10 {
			t.Fatalf("wrong or unbounded rendered graphs: status%d bytes%d", get.Code, len(body))
		}
		for _, absent := range []string{"Whole image responses completed", "Requests for part", "Response body sent,", "Interrupted transfers and failed", "Daily totals for this selection", "UTC day</th>", "Directory sizes include"} {
			if strings.Contains(body, absent) {
				t.Fatal("removed prose/table remains", absent)
			}
		}
		for _, want := range []string{"Transferred data", "Downloads", `id="transfer-explanation"`, `aria-describedby="transfer-explanation"`, `role="img"`, `data-daily-graph`, "Exact purpose sentence with &lt;escaped&gt; text"} {
			if !strings.Contains(body, want) {
				t.Fatal("missing graph/help/header semantics", want)
			}
		}
		if strings.Count(body, `tabindex="0" data-daily-graph`) != 2 {
			t.Fatal("graphs must have one keyboard entry each")
		}
		section := body[strings.Index(body, `<div class="usage-graphs">`):strings.Index(body, `<nav aria-label="Usage selection">`)]
		if initial == "" {
			initial = section
		} else if section != initial {
			t.Fatal("ranked cursor changed the full-selection timeline")
		}
		head := requestHTTP(h, "HEAD", "/usage?"+q.Encode(), nil)
		if head.Body.Len() != 0 || head.Header().Get("Content-Length") != get.Header().Get("Content-Length") {
			t.Fatal("graph HEAD differs")
		}
		t.Logf("365 days: %d bytes", len(body))
	}
	// Graph preparation consumes only the single existing usage read.
	if f.usageCalls != 4 {
		t.Fatal("extra usage read", f.usageCalls)
	}
	f.usageError = fmt.Errorf("private unavailable snapshot")
	body := requestHTTP(h, "GET", "/usage", nil).Body.String()
	if strings.Contains(body, "daily-graph") || strings.Contains(body, "private unavailable") {
		t.Fatal("error response includes a successful graph or private error")
	}
	// Existing route-isolation tests also cover graph-enabled Usage. Images and
	// Status still make zero usage reads; graph code cannot add backend queries.
	for _, path := range []string{"/images", "/status"} {
		old := f.usageCalls
		requestHTTP(h, "GET", path, nil)
		if f.usageCalls != old {
			t.Fatal("non-Usage page queried graph data")
		}
	}
}

func TestDashboardGraphsDownloadMidpointLabels(t *testing.T) {
	for _, tc := range []struct {
		maximum int64
		middle  string
	}{{1, ""}, {3, ""}, {4, "2"}} {
		usage := graphUsageFixture(1)
		usage.Days[0].FullDownloads = tc.maximum
		usage.Totals.FullDownloads = tc.maximum
		graphs, err := dashboardGraphs(usage)
		if err != nil {
			t.Fatal(err)
		}
		downloads := graphs[1]
		if downloads.Maximum != strconv.FormatInt(tc.maximum, 10) || downloads.Middle != tc.middle || downloads.Points[0].Height != "180.000" {
			t.Fatalf("max%d: incorrect count label or changed geometry: %+v", tc.maximum, downloads)
		}
	}
}
