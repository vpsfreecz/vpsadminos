package reposerver

import (
	"context"
	"fmt"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
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
	for _, want := range []string{"vpsAdminOS container images", "Repository status", "Available history is incomplete", "12 GiB", "Last 365 days", "opaque-next-page", "Skip to content", "Completed full-image responses"} {
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
	if got.Code != 409 || !strings.Contains(got.Body.String(), "page changed") || strings.Contains(got.Body.String(), "private database") {
		t.Fatal(got.Code, got.Body.String())
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

func TestDashboardUILegacyDirectoryPagination(t *testing.T) {
	old := publicDashboard{}
	for i := 0; i < 65; i++ {
		old.Images = append(old.Images, catalogRow{Tuple: Tuple{Distribution: "debian", Version: fmt.Sprintf("%d", i)}, Downloads: []downloadLink{{Format: "tar", URL: fmt.Sprintf("/v1/image-%d", i)}}})
	}
	first := legacyDashboardPage(old, httptest.NewRequest("GET", "/runs/key/v1/", nil))
	if len(first.CatalogRows) != 50 || first.CatalogNext != "/runs/key/v1/?catalog_offset=50#images" {
		t.Fatal(len(first.CatalogRows), first.CatalogNext)
	}
	// Browsers keep the fragment locally; it is never sent in the HTTP target.
	nextURL, err := url.Parse(first.CatalogNext)
	if err != nil {
		t.Fatal(err)
	}
	second := legacyDashboardPage(old, httptest.NewRequest("GET", nextURL.RequestURI(), nil))
	if len(second.CatalogRows) != 15 || second.CatalogRows[0].Version != "50" || second.CatalogNext != "" {
		t.Fatal(len(second.CatalogRows), second.CatalogNext)
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
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
}
