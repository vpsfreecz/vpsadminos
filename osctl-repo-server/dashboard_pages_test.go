package reposerver

import (
	"context"
	"fmt"
	"net/http/httptest"
	"net/url"
	"regexp"
	"strings"
	"testing"
	"time"
)

func TestDashboardSeparatePagesReadOnlySelectedSection(t *testing.T) {
	for _, tc := range []struct {
		path, page     string
		usage, catalog int
	}{{"/", "usage", 1, 1}, {"/usage", "usage", 1, 1}, {"/images", "images", 0, 1}, {"/status", "status", 0, 0}, {"/v1/", "images", 0, 1}, {"/?catalog_distribution=debian", "images", 0, 1}} {
		t.Run(tc.path, func(t *testing.T) {
			f := &uiDashboardFixture{versions: 10000}
			h := NewHTTPHandler(newFixtureReader(t), HTTPOptions{Repository: "repo", Dashboard: f})
			response := requestHTTP(h, "GET", tc.path, nil)
			if response.Code != 200 || f.usageCalls != tc.usage || len(f.catalogQueries) != tc.catalog || f.overviewCalls != 1 {
				t.Fatalf("wrong selected-page reads: status%d usage%d catalog%d overview%d", response.Code, f.usageCalls, len(f.catalogQueries), f.overviewCalls)
			}
			for _, page := range []string{"usage", "images", "status"} {
				if strings.Contains(response.Body.String(), `<section id="`+page+`"`) != (page == tc.page) {
					t.Fatal("unselected body rendered", page)
				}
			}
			for _, path := range []string{"/usage", "/images", "/status"} {
				if !strings.Contains(response.Body.String(), `href="`+path) {
					t.Fatal("ordinary page link absent", path)
				}
			}
		})
	}
}

func TestDashboardUsageSelectorsAreFiniteAndPreservePastValues(t *testing.T) {
	f := &uiDashboardFixture{}
	q := url.Values{"distribution": {"retired-distro"}, "arch": {"retired-arch"}, "vendor": {"retired-vendor"}, "variant": {"retired-variant"}, "version": {"retired-version"}, "period": {"365d"}}
	filters, problem := dashboardFilters(context.Background(), f, q)
	if problem != "" || len(f.catalogQueries) != 4 || f.usageCalls != 0 {
		t.Fatal("unexpected selector read", problem, len(f.catalogQueries), f.usageCalls)
	}
	for _, query := range f.catalogQueries {
		if query.Limit != 100 {
			t.Fatal("unbounded choices", query)
		}
	}
	for _, filter := range filters {
		if len(filter.Choices) > 102 || filter.Choices[0].Value != "" || filter.Choices[0].Label != "All" {
			t.Fatal("unbounded/missing All", filter.Name)
		}
		found := false
		for _, choice := range filter.Choices {
			if choice.Selected && choice.Value == q.Get(filter.Name) {
				found = true
				if !strings.Contains(choice.Label, "not listed") {
					t.Fatal("retired origin not disclosed")
				}
			}
		}
		if !found {
			t.Fatal("retired selection reset", filter.Name)
		}
		if filter.NextURL != "" {
			u, err := url.Parse(filter.NextURL)
			if err != nil || u.Path != "/usage" || u.Query().Get("period") != "365d" {
				t.Fatal("choice page lost context", u, err)
			}
		}
	}
	h := NewHTTPHandler(newFixtureReader(t), HTTPOptions{Repository: "repo", Dashboard: f})
	body := requestHTTP(h, "GET", "/usage?"+q.Encode(), nil).Body.String()
	for _, field := range []string{"Distribution", "Architecture", "Vendor", "Variant", "Version", "Grouping", "Period"} {
		if !strings.Contains(body, "<dt>"+field+"</dt>") {
			t.Fatal("applied summary omits", field)
		}
	}
	for _, value := range []string{"retired-distro", "retired-arch", "retired-vendor", "retired-variant", "retired-version", "365 days", "Image and variant"} {
		if !strings.Contains(body, "<dd>"+value+"</dd>") {
			t.Fatal("applied summary omits selected success", value)
		}
	}
	for _, field := range []string{"distribution", "arch", "vendor", "variant", "version"} {
		if !strings.Contains(body, `<select id="filter-`+field+`" name="`+field+`"`) {
			t.Fatal("labelled native selector missing", field)
		}
	}
	if !strings.Contains(body, `action="/usage"`) || !strings.Contains(body, `>Apply</button>`) || !strings.Contains(body, `>Clear</a>`) {
		t.Fatal("native GET form missing")
	}
	f.usageError = fmt.Errorf("private usage failure")
	body = requestHTTP(h, "GET", "/usage?"+q.Encode(), nil).Body.String()
	if strings.Contains(body, `aria-label="Applied selection"`) {
		t.Fatal("failed snapshot shows applied success summary")
	}
}

func TestDashboardHistoryNoticeIsClosedDisclosureBesideFrom(t *testing.T) {
	f := &uiDashboardFixture{}
	h := NewHTTPHandler(newFixtureReader(t), HTTPOptions{Dashboard: f})
	body := requestHTTP(h, "GET", "/usage", nil).Body.String()
	from := strings.Index(body, "From <time>")
	warning := strings.Index(body, `<details class="history-warning">`)
	to := strings.Index(body, "To <time>")
	if from < 0 || warning < from || to < warning || !strings.Contains(body, `aria-label="Incomplete history"`) {
		t.Fatal("warning not next to From")
	}
	if strings.Contains(body, `class="history-warning" open`) || strings.Contains(body, `<p class="notice">Available history`) {
		t.Fatal("persistent long warning")
	}
	if !strings.Contains(body, "Retention: 7 days") || !strings.Contains(body, "Missing records") {
		t.Fatal("coverage meaning lost")
	}
	// A closed details suppresses its non-summary subtree in native browsers.
	// Keep the explanation inside summary so CSS hover/focus can expose it
	// without changing native open state before a click/Enter/tap.
	warningHTML := regexp.MustCompile(`<details class="history-warning">(.*?)</details>`).FindStringSubmatch(body)
	if len(warningHTML) != 2 {
		t.Fatal("warning disclosure absent")
	}
	summary := regexp.MustCompile(`^<summary[^>]*aria-describedby="history-explanation"[^>]*>(.*?)</summary>$`).FindStringSubmatch(warningHTML[1])
	if len(summary) != 2 || !strings.Contains(summary[1], `<span id="history-explanation" class="history-explanation" role="note">History is incomplete.`) {
		t.Fatal("explanation is suppressed by closed details or has no accessible description")
	}
}

func TestDashboardHistoricalImageUsageLinksCarryCompleteTuple(t *testing.T) {
	q := url.Values{"period": {"365d"}, "distribution": {"old-selection"}, "arch": {"old-arch"}}
	page := newDashboardPage(DashboardOverview{}, CatalogPage{}, UsagePage{Period: "365d", GroupBy: "image", Rows: []UsageRow{{Tuple: Tuple{Distribution: "retired-distro", Arch: "retired-arch", Vendor: "retired-vendor", Variant: "retired-variant", Version: "1"}}}}, q)
	if len(page.UsageRows) != 1 {
		t.Fatal(page)
	}
	u, err := url.Parse(page.UsageRows[0].URL)
	if err != nil {
		t.Fatal(err)
	}
	for key, want := range map[string]string{"distribution": "retired-distro", "arch": "retired-arch", "vendor": "retired-vendor", "variant": "retired-variant", "version": "1", "period": "365d"} {
		if u.Query().Get(key) != want {
			t.Fatal("image usage link lost selector", key, u)
		}
	}
}

func TestDashboardImagesExpandedAncestorMetadata(t *testing.T) {
	known := time.Date(2026, 11, 9, 8, 7, 6, 0, time.UTC)
	// Equal display labels at different depths must still bind exact tuples.
	q := url.Values{"catalog_distribution": {"same"}, "catalog_arch": {"same"}, "catalog_vendor": {"vendor"}, "catalog_variant": {"minimal"}}
	ancestors := []CatalogRow{
		{Tuple: Tuple{Distribution: "same"}, Bytes: 1024, LastModified: &known, ImageVersions: 9},
		{Tuple: Tuple{Distribution: "same", Arch: "same"}, Bytes: 2048, ImageVersions: 7},
		{Tuple: Tuple{Distribution: "same", Arch: "same", Vendor: "vendor", Variant: "minimal"}, Bytes: 3072, LastModified: &known, ImageVersions: 5},
	}
	leaf := CatalogRow{Tuple: Tuple{Distribution: "same", Arch: "same", Vendor: "vendor", Variant: "minimal", Version: "1"}, Bytes: 1536, Downloads: []DashboardDownload{{Format: "tar", URL: "/v1/vendor/minimal/same/same/1/image-archive.tar", Bytes: 1536, LastModified: &known}, {Format: "zfs", URL: "/v1/vendor/minimal/same/same/1/image-stream.tar", Bytes: 0}}}
	render := func(parents []CatalogRow) string {
		page := newDashboardPage(DashboardOverview{}, CatalogPage{GroupBy: "version", Ancestors: parents, Rows: []CatalogRow{leaf}}, UsagePage{}, q)
		page.Page = "images"
		w := httptest.NewRecorder()
		writeDashboardPage(w, httptest.NewRequest("GET", "/images", nil), page, 200)
		if w.Code != 200 {
			t.Fatal(w.Code)
		}
		return w.Body.String()
	}
	body := render(ancestors)
	lines := regexp.MustCompile(`<div class="tree-link">(.*?)</div>`).FindAllString(body, -1)
	if len(lines) != 4 {
		t.Fatal("missing ancestors", len(lines))
	}
	for i, want := range []string{"1 KiB", "2 KiB", "3 KiB", "1.5 KiB"} {
		if !strings.Contains(lines[i], want) || !strings.Contains(lines[i], `class="listing-metadata"`) {
			t.Fatal("expanded metadata missing or misbound", i, lines[i])
		}
	}
	if !strings.Contains(lines[1], `aria-label="Last modified unknown"`) || strings.Contains(lines[1], "2026-") {
		t.Fatal("unknown ancestor date fabricated")
	}
	if strings.Count(body, "2026-11-09 08:07:06 UTC") != 3 || strings.Contains(body, "0001-") {
		t.Fatal("file/directory dates incorrect")
	}
	if !strings.Contains(body, `title="1536 bytes"`) || !strings.Contains(body, `aria-label="Last modified unknown"`) {
		t.Fatal("file metadata missing")
	}
	missing := render(ancestors[:1])
	missingLines := regexp.MustCompile(`<div class="tree-link">(.*?)</div>`).FindAllString(missing, -1)
	for _, line := range missingLines[1:3] {
		if !strings.Contains(line, "Metadata unavailable") || strings.Contains(line, `title="0 bytes"`) {
			t.Fatal("missing ancestor metadata presented as zero")
		}
	}
}

func TestDashboardUsageChoiceCursorKeepsSelection(t *testing.T) {
	f := &uiDashboardFixture{}
	q := url.Values{"distribution": {"retired"}, "period": {"90d"}, "options_distribution_cursor": {"page2"}}
	filters, problem := dashboardFilters(context.Background(), f, q)
	if problem != "" || len(f.catalogQueries) != 2 || f.catalogQueries[0].Cursor != "page2" || f.catalogQueries[0].Limit != 100 {
		t.Fatal("choice cursor not passed", problem, f.catalogQueries)
	}
	for _, option := range filters[0].Choices {
		if option.Value == "retired" && option.Selected {
			return
		}
	}
	t.Fatal("selected value disappeared on next choices page")
}
