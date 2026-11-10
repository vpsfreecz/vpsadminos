package reposerver

import (
	"context"
	"errors"
	"fmt"
	"html"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

type uiDashboardFixture struct {
	catalogQuery             CatalogQuery
	usageQuery               UsageQuery
	catalogError, usageError error
	overviewError            error
	versions                 int
}

func (f *uiDashboardFixture) DashboardOverview(context.Context) (DashboardOverview, error) {
	return DashboardOverview{DashboardMetadata: DashboardMetadata{Repository: "public", Instance: "test", APIVersion: 1}, Generation: "opaque-catalog-id-not-source-sha", ImageVersions: int64(f.versions), StorageFiles: 24000, StorageBytes: 12 << 30, RunStates: map[string]int64{"open": 2, "finished": 3, "sealed": 4}, ItemStates: map[string]int64{"queued": 2, "running": 1, "verified": 42, "failed": 3}}, f.overviewError
}

func (f *uiDashboardFixture) DashboardCatalog(_ context.Context, q CatalogQuery) (CatalogPage, error) {
	f.catalogQuery = q
	p := CatalogPage{GroupBy: q.GroupBy}
	for i := 0; i < q.Limit; i++ {
		row := CatalogRow{Tuple: Tuple{Distribution: fmt.Sprintf("distribution-%03d", i), Arch: "x86_64", Vendor: "vpsadminos", Variant: "minimal", Version: fmt.Sprintf("%d", i)}, ImageVersions: 200, Tags: []string{"latest", "stable"}}
		if q.GroupBy == "version" {
			row.Downloads = []DashboardDownload{{Format: "tar", URL: "/v1/vpsadminos/minimal/x86_64/debian/13/image-archive.tar", Bytes: 1536}}
		}
		p.Rows = append(p.Rows, row)
	}
	if q.Cursor == "" {
		p.NextCursor = "opaque-next-page"
	}
	return p, f.catalogError
}

func (f *uiDashboardFixture) DashboardUsage(_ context.Context, q UsageQuery) (UsagePage, error) {
	f.usageQuery = q
	now := time.Date(2026, 11, 10, 12, 0, 0, 0, time.UTC)
	from := now.AddDate(0, 0, -5)
	p := UsagePage{Period: q.Period, GroupBy: q.GroupBy, Start: now.AddDate(0, 0, -6), End: now, UpdatedAt: &now, Coverage: UsageCoverage{RetainedFrom: &from, RetentionDays: 7, HistoryComplete: false}, Totals: UsageCounters{FullDownloads: 12000, RangeRequests: 300, TransferredBytes: 9 << 30, InterruptedRequests: 2, ErrorRequests: 1}}
	p.Rows = []UsageRow{{Tuple: Tuple{Distribution: "debian", Arch: "x86_64", Vendor: "vpsadminos", Variant: "minimal", Version: "13"}, UsageCounters: p.Totals}}
	for i := 0; i < 365; i++ {
		p.Days = append(p.Days, UsageDay{Day: now.AddDate(0, 0, -i).Format("2006-01-02"), UsageCounters: UsageCounters{FullDownloads: 12, TransferredBytes: 1536}})
	}
	return p, f.usageError
}

func TestDashboardUIBoundsAndNoLegacyRead(t *testing.T) {
	f := &uiDashboardFixture{versions: 10000}
	reader := newFixtureReader(t)
	reader.err = &Error{Code: "integrity", Message: "legacy Reader must not be called for bounded UI"}
	h := NewHTTPHandler(reader, HTTPOptions{Repository: "repo", Dashboard: f})
	response := requestHTTP(h, "GET", "/", nil)
	if response.Code != 200 {
		t.Fatal(response.Code, response.Body.String())
	}
	body := response.Body.String()
	if f.catalogQuery.Limit != 50 || f.catalogQuery.GroupBy != "distribution" || f.usageQuery.Period != "7d" || f.usageQuery.Limit != 50 {
		t.Fatalf("unbounded or wrong default query: %+v %+v", f.catalogQuery, f.usageQuery)
	}
	if strings.Count(body, "class=\"tree-link\"") != 50 || len(body) > 256<<10 {
		t.Fatalf("unexpected rendered size: %d bytes", len(body))
	}
	for _, want := range []string{"Repository status", "Available history is incomplete", "12 GiB", "365 days", "90 days", "180 days", "opaque-next-page", "Skip to content", "Completed full-image responses"} {
		if !strings.Contains(body, want) {
			t.Fatal("missing", want)
		}
	}
	for _, forbidden := range []string{"private-user-agent", "private-client-ip", "/dashboard.json", "unsafe-inline", "<script>"} {
		if strings.Contains(body, forbidden) {
			t.Fatal("unwanted UI content", forbidden)
		}
	}
	if !strings.Contains(response.Header().Get("Content-Security-Policy"), "script-src 'self'") || response.Header().Get("Cache-Control") != "no-store" {
		t.Fatal(response.Header())
	}
	technical := strings.Index(body, "<details class=\"technical\">")
	if technical < 0 || strings.Index(body, "opaque-catalog-id-not-source-sha") < technical {
		t.Fatal("opaque catalog ID promoted outside technical details")
	}
	if head := requestHTTP(h, "HEAD", "/", nil); head.Code != 200 || head.Body.Len() != 0 || head.Header().Get("Content-Length") != response.Header().Get("Content-Length") {
		t.Fatal("HEAD mismatch", head.Header(), head.Body.Len())
	}
	t.Logf("10,000-version fixture: 50 initial rows + 365 bounded daily rows, %d HTML bytes", len(body))
}

func TestDashboardUIOperatorIdentityAndUsageFirst(t *testing.T) {
	f := &uiDashboardFixture{versions: 5000}
	h := NewHTTPHandler(newFixtureReader(t), HTTPOptions{Repository: "stable-key", DisplayName: "CI <North>", Purpose: "Shared <em>build cache</em>", Dashboard: f})
	got := requestHTTP(h, "GET", "/", nil)
	body := got.Body.String()
	if got.Code != 200 || !strings.Contains(body, "<h1>CI &lt;North&gt;</h1>") || !strings.Contains(body, "Shared &lt;em&gt;build cache&lt;/em&gt;") {
		t.Fatal(got.Code, body)
	}
	if strings.Index(body, "<section id=\"usage\"") > strings.Index(body, "<section id=\"images\"") {
		t.Fatal("usage not first")
	}
	for _, removed := range []string{"Download container images for vpsAdminOS", "Open a group", "Showing ", "Next page", "<select"} {
		if strings.Contains(body, removed) {
			t.Fatal("unwanted dominant/paging copy", removed)
		}
	}
	for _, theme := range []string{"system", "light", "dark"} {
		if !strings.Contains(body, "data-theme-choice=\""+theme+"\"") || !strings.Contains(body, "aria-label=\""+strings.ToUpper(theme[:1])+theme[1:]+" theme\"") {
			t.Fatal("missing accessible icon", theme)
		}
	}
	h = NewHTTPHandler(newFixtureReader(t), HTTPOptions{Repository: "stable-key", Dashboard: f})
	body = requestHTTP(h, "GET", "/", nil).Body.String()
	if !strings.Contains(body, "<h1>stable-key</h1>") || strings.Contains(body, "class=\"purpose\"") {
		t.Fatal("empty identity fallback/description")
	}
}

func TestDashboardUITreeAncestorsAndLongPeriods(t *testing.T) {
	q := url.Values{"catalog_distribution": {"debian"}, "catalog_arch": {"x86_64"}, "catalog_vendor": {"vpsadminos"}, "catalog_variant": {"minimal"}, "period": {"180d"}, "distribution": {"alpine"}}
	d := newDashboardPage(DashboardOverview{}, CatalogPage{GroupBy: "version", Rows: []CatalogRow{{Tuple: Tuple{Distribution: "debian", Arch: "x86_64", Vendor: "vpsadminos", Variant: "minimal", Version: "13"}, Tags: []string{"stable"}}}}, UsagePage{Period: "180d"}, q)
	branch := d.Tree
	for _, want := range []string{"debian", "x86_64", "vpsadminos / minimal"} {
		if len(branch) != 1 || branch[0].Label != want || !branch[0].Expanded {
			t.Fatal("ancestor lost", want, branch)
		}
		url, _ := url.Parse(branch[0].URL)
		if url.Query().Get("distribution") != "alpine" || url.Query().Get("period") != "180d" {
			t.Fatal("catalog expansion changed usage", url)
		}
		branch = branch[0].Children
	}
	if len(branch) != 1 || branch[0].Label != "13" {
		t.Fatal("selected leaf lost", branch)
	}
	seen := map[string]bool{}
	for _, period := range d.Periods {
		u, _ := url.Parse(period.URL)
		seen[u.Query().Get("period")] = true
		if period.Selected && u.Query().Get("period") != "180d" {
			t.Fatal("wrong selected period")
		}
	}
	if !seen["90d"] || !seen["180d"] || len(seen) != 6 {
		t.Fatal(seen)
	}
}

func TestDashboardUINavigationAndFilters(t *testing.T) {
	f := &uiDashboardFixture{versions: 10000}
	h := NewHTTPHandler(newFixtureReader(t), HTTPOptions{Repository: "repo", Dashboard: f})
	paths := []struct{ path, group string }{
		{"/?catalog_distribution=debian", "arch"},
		{"/?catalog_distribution=debian&catalog_arch=x86_64", "variant"},
		{"/?catalog_distribution=debian&catalog_arch=x86_64&catalog_vendor=vpsadminos&catalog_variant=minimal", "version"},
	}
	for _, tc := range paths {
		got := requestHTTP(h, "GET", tc.path, nil)
		if got.Code != 200 || f.catalogQuery.GroupBy != tc.group {
			t.Fatal(tc, got.Code, f.catalogQuery)
		}
		if tc.group == "version" && (!strings.Contains(got.Body.String(), "1.5 KiB") || !strings.Contains(got.Body.String(), "1536 bytes") || !strings.Contains(got.Body.String(), "image-archive.tar")) {
			t.Fatal("leaf downloads missing")
		}
	}
	requestHTTP(h, "GET", "/?period=365d&distribution=debian&arch=x86_64&vendor=vpsadminos&variant=minimal&version=13&usage_cursor=next", nil)
	if f.usageQuery.Period != "365d" || f.usageQuery.GroupBy != "image" || f.usageQuery.Cursor != "next" || f.usageQuery.Version != "13" {
		t.Fatal(f.usageQuery)
	}
	q := url.Values{"catalog_distribution": {"debian"}, "catalog_arch": {"x86_64"}, "catalog_vendor": {"vpsadminos"}, "catalog_variant": {"minimal"}}
	p := newDashboardPage(DashboardOverview{}, CatalogPage{GroupBy: "version"}, UsagePage{}, q)
	for _, crumb := range p.CatalogCrumbs {
		u, _ := url.Parse(crumb.URL)
		v := u.Query()
		if (v.Get("catalog_vendor") == "") != (v.Get("catalog_variant") == "") {
			t.Fatal("partial vendor/variant breadcrumb", crumb)
		}
	}
}

func TestDashboardUIEscapingAndErrors(t *testing.T) {
	p := newDashboardPage(DashboardOverview{DashboardMetadata: DashboardMetadata{Repository: "<script>secret()</script>"}}, CatalogPage{GroupBy: "version", Rows: []CatalogRow{{Tuple: Tuple{Version: "<img src=x onerror=secret()>"}, Downloads: []DashboardDownload{{Format: "<script>", URL: "javascript:secret()", Bytes: 1024}}}}}, UsagePage{}, url.Values{})
	w := httptest.NewRecorder()
	writeDashboardPage(w, httptest.NewRequest("GET", "/", nil), p, 200)
	if strings.Contains(w.Body.String(), "<script>secret") || strings.Contains(w.Body.String(), "<img src") || strings.Contains(w.Body.String(), "href=\"javascript:") {
		t.Fatal("unescaped catalog data", w.Body.String())
	}
	f := &uiDashboardFixture{catalogError: &Error{Code: "conflict", Message: "private database path"}}
	h := NewHTTPHandler(newFixtureReader(t), HTTPOptions{Dashboard: f})
	got := requestHTTP(h, "GET", "/?catalog_cursor=old", nil)
	if got.Code != 409 || !strings.Contains(got.Body.String(), "expired or changed") || strings.Contains(got.Body.String(), "private database") {
		t.Fatal("cursor conflict status or safe message", got.Code)
	}
	f.catalogError = nil
	f.usageError = fmt.Errorf("private sqlite path")
	got = requestHTTP(h, "GET", "/", nil)
	if got.Code != 503 || !strings.Contains(got.Body.String(), "temporarily unavailable") || strings.Contains(got.Body.String(), "No measured public image traffic") || strings.Contains(got.Body.String(), "private sqlite") {
		t.Fatal(got.Code, got.Body.String())
	}
	f.overviewError = fmt.Errorf("private overview database path")
	got = requestHTTP(h, "GET", "/", nil)
	if got.Code != 503 || !strings.Contains(got.Body.String(), "temporarily unavailable") || strings.Contains(got.Body.String(), "private overview") {
		t.Fatal(got.Code, got.Body.String())
	}
}

func TestDashboardUIUsageDeadlineGuidance(t *testing.T) {
	for _, tc := range []struct {
		name     string
		err      error
		deadline bool
	}{
		{"deadline", context.DeadlineExceeded, true},
		{"wrapped deadline", fmt.Errorf("private query context: %w", context.DeadlineExceeded), true},
		{"caller cancelled", context.Canceled, false},
		{"wrapped caller cancelled", fmt.Errorf("private query context: %w", context.Canceled), false},
		{"cancelled with deadline", errors.Join(context.Canceled, context.DeadlineExceeded), false},
		{"database failure", errors.New("private database path failed"), false},
		{"deadline text only", errors.New("context deadline exceeded"), false},
		{"memory refusal", problem("bounded", "private bounded-result refusal"), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := &uiDashboardFixture{usageError: tc.err}
			h := NewHTTPHandler(newFixtureReader(t), HTTPOptions{Repository: "test", Dashboard: f})
			response := requestHTTP(h, "GET", "/", nil)
			want, _ := dashboardReadError(tc.err)
			if tc.deadline {
				var ok bool
				want, ok = usageDeadlineMessage(tc.err)
				if !ok {
					t.Fatal("deadline helper did not classify wrapped usage deadline")
				}
			}
			if response.Code != 503 || response.Header().Get("Cache-Control") != "no-store" || !strings.Contains(response.Body.String(), html.EscapeString(want)) {
				t.Fatal("incorrect HTML usage error boundary", response.Code)
			}
			if strings.Contains(response.Body.String(), "private") || strings.Contains(response.Body.String(), "No measured public image traffic") {
				t.Fatal("private error or fabricated empty success in HTML")
			}
		})
	}
	// The helper is specific to usage: a catalog deadline keeps its existing
	// generic message even though the usage selection succeeds independently.
	f := &uiDashboardFixture{catalogError: fmt.Errorf("private catalog context: %w", context.DeadlineExceeded)}
	response := requestHTTP(NewHTTPHandler(newFixtureReader(t), HTTPOptions{Dashboard: f}), "GET", "/", nil)
	want, _ := dashboardReadError(f.catalogError)
	deadlineMessage, _ := usageDeadlineMessage(context.DeadlineExceeded)
	if response.Code != 503 || !strings.Contains(response.Body.String(), html.EscapeString(want)) || strings.Contains(response.Body.String(), html.EscapeString(deadlineMessage)) {
		t.Fatal("catalog error gained usage guidance", response.Code)
	}
}

func TestDashboardUILegacyDirectoryPagination(t *testing.T) {
	for _, base := range []string{"/v1/", "/v1/vendor/minimal/x86_64/debian/", "/runs/sealed-key/v1/"} {
		t.Run(base, func(t *testing.T) {
			old := publicDashboard{}
			for i := 0; i < 65; i++ {
				old.Images = append(old.Images, catalogRow{Tuple: Tuple{Distribution: "debian", Version: fmt.Sprintf("%d", i)}, Downloads: []downloadLink{{Format: "tar", URL: fmt.Sprintf("%simage-%d", base, i)}}})
			}
			render := func(target string) string {
				r := httptest.NewRequest("GET", target, nil)
				w := httptest.NewRecorder()
				writeDashboardPage(w, r, legacyDashboardPage(old, r), 200)
				if w.Code != 200 {
					t.Fatalf("render status %d", w.Code)
				}
				return w.Body.String()
			}
			first := render(base)
			match := regexp.MustCompile(`<a href="([^"]+)">More</a>`).FindStringSubmatch(first)
			if len(match) != 2 {
				t.Fatal("rendered first page lacks More")
			}
			nextURL, err := url.Parse(html.UnescapeString(match[1]))
			if err != nil {
				t.Fatal(err)
			}
			if nextURL.Path != base || nextURL.Query().Get("catalog_offset") != "50" {
				t.Fatal("More substituted listing scope", nextURL)
			}
			if strings.Count(first, `<li data-catalog-node>`) != 50 || strings.Contains(first, fmt.Sprintf(`href="%simage-50"`, base)) {
				t.Fatal("incorrect first page bounds")
			}
			// Fragments stay in the browser and never enter the HTTP target.
			second := render(nextURL.RequestURI())
			if strings.Count(second, `<li data-catalog-node>`) != 15 || regexp.MustCompile(`<a href="[^"]+">More</a>`).MatchString(second) {
				t.Fatal("incorrect final page bounds or redundant More")
			}
			for i := 50; i < 65; i++ {
				if !strings.Contains(second, fmt.Sprintf(`href="%simage-%d"`, base, i)) {
					t.Fatalf("image %d unreachable in original scope", i)
				}
			}
		})
	}
}

func TestDashboardUIAssetsAndUnits(t *testing.T) {
	for _, path := range []string{"/dashboard/assets/style.css", "/dashboard/assets/theme.js"} {
		get := httptest.NewRecorder()
		if !dashboardAssets(get, httptest.NewRequest("GET", path, nil)) || get.Code != 200 {
			t.Fatal(path, get.Code)
		}
		head := httptest.NewRecorder()
		dashboardAssets(head, httptest.NewRequest("HEAD", path, nil))
		if head.Body.Len() != 0 || head.Header().Get("Content-Length") != get.Header().Get("Content-Length") {
			t.Fatal("asset HEAD", path)
		}
		post := httptest.NewRecorder()
		dashboardAssets(post, httptest.NewRequest("POST", path, nil))
		if post.Code != 405 {
			t.Fatal(post.Code)
		}
	}
	for n, want := range map[int64]string{0: "0 B", 1023: "1023 B", 1024: "1 KiB", 1536: "1.5 KiB", 1048576: "1 MiB", 1 << 30: "1 GiB", 1 << 40: "1 TiB"} {
		if got := iecBytes(n); got != want {
			t.Fatal(n, got, want)
		}
	}
}

// An optional static artifact is useful for a local file render: no server,
// network or browser is launched by the test. The runtime UI uses origin URLs.
func TestDashboardUIRenderArtifact(t *testing.T) {
	dir := os.Getenv("DASHBOARD_RENDER_DIR")
	if dir == "" {
		t.Skip("no static render requested")
	}
	f := &uiDashboardFixture{versions: 10000}
	o, _ := f.DashboardOverview(context.Background())
	c, _ := f.DashboardCatalog(context.Background(), CatalogQuery{GroupBy: "distribution", Limit: 8})
	u, _ := f.DashboardUsage(context.Background(), UsageQuery{Period: "7d", GroupBy: "distribution"})
	w := httptest.NewRecorder()
	writeDashboardPage(w, httptest.NewRequest("GET", "/", nil), newDashboardPage(o, c, u, url.Values{}), 200)
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	files := map[string]string{"index.html": strings.ReplaceAll(w.Body.String(), "/dashboard/assets/", "./"), "style.css": dashboardCSS, "theme.js": dashboardJS}
	q := url.Values{"catalog_distribution": {"distribution-000"}, "catalog_arch": {"x86_64"}, "catalog_vendor": {"vpsadminos"}, "catalog_variant": {"minimal"}}
	contextCatalog, _ := f.DashboardCatalog(context.Background(), catalogPageQuery(q))
	contextWriter := httptest.NewRecorder()
	writeDashboardPage(contextWriter, httptest.NewRequest("GET", "/", nil), newDashboardPage(o, contextCatalog, u, q), 200)
	files["context.html"] = strings.ReplaceAll(contextWriter.Body.String(), "/dashboard/assets/", "./")
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
}
