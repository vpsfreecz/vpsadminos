package reposerver

import (
	"bytes"
	_ "embed"
	"errors"
	"fmt"
	"html/template"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

//go:embed dashboard.html
var dashboardHTMLSource string

//go:embed dashboard.css
var dashboardCSS string

//go:embed dashboard.js
var dashboardJS string

type dashboardLink struct {
	Label, URL string
	Selected   bool
}

type dashboardCatalogRow struct {
	CatalogRow
	Label, URL string
}

type dashboardUsageRow struct {
	UsageRow
	Label, URL string
}

type dashboardTreeNode struct {
	Label, URL, ParentURL, UsageURL, Query string
	ImageVersions                          int64
	Tags                                   []string
	Downloads                              []DashboardDownload
	Children                               []dashboardTreeNode
	Expanded, More                         bool
}

type dashboardPage struct {
	Name, Purpose                             string
	Enhanced                                  bool
	Overview                                  DashboardOverview
	Usage                                     UsagePage
	CatalogRows                               []dashboardCatalogRow
	UsageRows                                 []dashboardUsageRow
	CatalogCrumbs, UsageCrumbs, Periods       []dashboardLink
	CatalogNext, UsageNext                    string
	CatalogRestart, UsageRestart              string
	CatalogError, UsageError, UsageGroupLabel string
	WorkSummary, RunSummary                   string
	CatalogRowLabel                           string
	Tree                                      []dashboardTreeNode
	CatalogQuery                              string
}

func iecBytes(n int64) string {
	if n < 1024 {
		return strconv.FormatInt(n, 10) + " B"
	}
	v, unit := float64(n), 0
	units := []string{"B", "KiB", "MiB", "GiB", "TiB"}
	for v >= 1024 && unit < len(units)-1 {
		v /= 1024
		unit++
	}
	return strings.TrimSuffix(fmt.Sprintf("%.1f", v), ".0") + " " + units[unit]
}

var dashboardTemplate = template.Must(template.New("dashboard").Funcs(template.FuncMap{
	"iec":          iecBytes,
	"utc":          func(t time.Time) string { return t.UTC().Format("2006-01-02 15:04:05") },
	"importantTag": func(t string) bool { return t == "latest" || t == "stable" },
}).Parse(dashboardHTMLSource))

func dashboardAssets(w http.ResponseWriter, r *http.Request) bool {
	var body, contentType string
	switch r.URL.Path {
	case "/dashboard/assets/style.css":
		body, contentType = dashboardCSS, "text/css; charset=utf-8"
	case "/dashboard/assets/theme.js":
		body, contentType = dashboardJS, "text/javascript; charset=utf-8"
	default:
		return false
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return true
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	if r.Method != http.MethodHead {
		_, _ = w.Write([]byte(body))
	}
	return true
}

func dashboardURL(q url.Values, anchor string) string {
	return "/?" + q.Encode() + "#" + anchor
}

func copyDashboardQuery(q url.Values) url.Values {
	out := url.Values{}
	// Only public navigation dimensions belong in links, never arbitrary query
	// values or requester input copied into the page.
	for _, k := range []string{"catalog_distribution", "catalog_arch", "catalog_vendor", "catalog_variant", "catalog_cursor", "period", "distribution", "arch", "vendor", "variant", "version", "usage_cursor"} {
		if v := q.Get(k); v != "" {
			out.Set(k, v)
		}
	}
	return out
}

func catalogPageQuery(q url.Values) CatalogQuery {
	c := CatalogQuery{GroupBy: "distribution", Distribution: q.Get("catalog_distribution"), Arch: q.Get("catalog_arch"), Vendor: q.Get("catalog_vendor"), Variant: q.Get("catalog_variant"), Cursor: q.Get("catalog_cursor"), Limit: 50}
	if c.Distribution != "" {
		c.GroupBy = "arch"
	}
	if c.Arch != "" {
		c.GroupBy = "variant"
	}
	if c.Vendor != "" || c.Variant != "" {
		c.GroupBy = "version"
	}
	return c
}

func usagePageQuery(q url.Values) UsageQuery {
	u := UsageQuery{Period: q.Get("period"), GroupBy: "distribution", Distribution: q.Get("distribution"), Arch: q.Get("arch"), Vendor: q.Get("vendor"), Variant: q.Get("variant"), Version: q.Get("version"), Cursor: q.Get("usage_cursor"), Limit: 50}
	if u.Period == "" {
		u.Period = "7d"
	}
	if u.Distribution != "" {
		u.GroupBy = "arch"
	}
	if u.Arch != "" || u.Vendor != "" || u.Variant != "" || u.Version != "" {
		u.GroupBy = "image"
	}
	return u
}

func newDashboardPage(overview DashboardOverview, catalog CatalogPage, usage UsagePage, q url.Values) dashboardPage {
	d := dashboardPage{Overview: overview, Usage: usage, UsageGroupLabel: "Usage by distribution", CatalogRowLabel: "distributions"}
	d.Name, d.Purpose, d.Enhanced = overview.DisplayName, overview.Purpose, true
	if d.Name == "" {
		d.Name = overview.Repository
	}
	cq, uq := catalogPageQuery(q), usagePageQuery(q)
	switch catalog.GroupBy {
	case "arch":
		d.CatalogRowLabel = "architectures"
	case "variant":
		d.CatalogRowLabel = "vendor / variant pairs"
	case "version":
		d.CatalogRowLabel = "versions"
	}
	base := copyDashboardQuery(q)
	restart := copyDashboardQuery(base)
	for _, k := range []string{"catalog_distribution", "catalog_arch", "catalog_vendor", "catalog_variant", "catalog_cursor"} {
		restart.Del(k)
	}
	d.CatalogRestart = dashboardURL(restart, "images")
	d.CatalogCrumbs = []dashboardLink{{Label: "Distributions", URL: d.CatalogRestart}}
	for _, part := range []struct{ k, label string }{{"catalog_distribution", cq.Distribution}, {"catalog_arch", cq.Arch}} {
		if part.label != "" {
			restart.Set(part.k, part.label)
			d.CatalogCrumbs = append(d.CatalogCrumbs, dashboardLink{Label: part.label, URL: dashboardURL(restart, "images")})
		}
	}
	if cq.Vendor != "" && cq.Variant != "" {
		restart.Set("catalog_vendor", cq.Vendor)
		restart.Set("catalog_variant", cq.Variant)
		d.CatalogCrumbs = append(d.CatalogCrumbs, dashboardLink{Label: cq.Vendor + " / " + cq.Variant, URL: dashboardURL(restart, "images")})
	}
	for _, row := range catalog.Rows {
		view := dashboardCatalogRow{CatalogRow: row}
		next := copyDashboardQuery(base)
		next.Del("catalog_cursor")
		switch catalog.GroupBy {
		case "distribution":
			view.Label = row.Distribution
			next.Set("catalog_distribution", row.Distribution)
		case "arch":
			view.Label = row.Arch
			next.Set("catalog_arch", row.Arch)
		case "variant":
			view.Label = row.Vendor + " / " + row.Variant
			next.Set("catalog_vendor", row.Vendor)
			next.Set("catalog_variant", row.Variant)
		case "version":
			view.Label = row.Version
		}
		if catalog.GroupBy != "version" {
			view.URL = dashboardURL(next, "images")
		}
		d.CatalogRows = append(d.CatalogRows, view)
	}
	if catalog.NextCursor != "" {
		next := copyDashboardQuery(base)
		next.Set("catalog_cursor", catalog.NextCursor)
		d.CatalogNext = dashboardURL(next, "images")
	}
	for _, period := range []struct{ value, label string }{{"today", "Today"}, {"7d", "7 days"}, {"30d", "30 days"}, {"90d", "90 days"}, {"180d", "180 days"}, {"365d", "365 days"}} {
		next := copyDashboardQuery(base)
		next.Del("usage_cursor")
		next.Set("period", period.value)
		d.Periods = append(d.Periods, dashboardLink{Label: period.label, URL: dashboardURL(next, "usage"), Selected: uq.Period == period.value})
	}
	restart = copyDashboardQuery(base)
	for _, k := range []string{"distribution", "arch", "vendor", "variant", "version", "usage_cursor"} {
		restart.Del(k)
	}
	d.UsageRestart = dashboardURL(restart, "usage")
	d.UsageCrumbs = []dashboardLink{{Label: "All public images", URL: d.UsageRestart}}
	for _, part := range []struct{ k, label string }{{"distribution", uq.Distribution}, {"arch", uq.Arch}} {
		if part.label != "" {
			restart.Set(part.k, part.label)
			d.UsageCrumbs = append(d.UsageCrumbs, dashboardLink{Label: part.label, URL: dashboardURL(restart, "usage")})
		}
	}
	if uq.Vendor != "" && uq.Variant != "" {
		restart.Set("vendor", uq.Vendor)
		restart.Set("variant", uq.Variant)
		if uq.Version != "" {
			restart.Set("version", uq.Version)
		}
		d.UsageCrumbs = append(d.UsageCrumbs, dashboardLink{Label: uq.Vendor + " / " + uq.Variant + " " + uq.Version, URL: dashboardURL(restart, "usage")})
	}
	if usage.GroupBy == "arch" {
		d.UsageGroupLabel = "Usage by architecture"
	}
	if usage.GroupBy == "image" {
		d.UsageGroupLabel = "Usage by image and variant"
	}
	for _, row := range usage.Rows {
		view := dashboardUsageRow{UsageRow: row}
		next := copyDashboardQuery(base)
		next.Del("usage_cursor")
		switch usage.GroupBy {
		case "distribution":
			view.Label = row.Distribution
			next.Set("distribution", row.Distribution)
		case "arch":
			view.Label = row.Arch
			next.Set("arch", row.Arch)
		case "image":
			view.Label = strings.Join([]string{row.Distribution, row.Version, row.Arch, row.Vendor + "/" + row.Variant}, " · ")
			next.Set("vendor", row.Vendor)
			next.Set("variant", row.Variant)
			next.Set("version", row.Version)
		}
		if uq.Version == "" {
			view.URL = dashboardURL(next, "usage")
		}
		d.UsageRows = append(d.UsageRows, view)
	}
	if usage.NextCursor != "" {
		next := copyDashboardQuery(base)
		next.Set("usage_cursor", usage.NextCursor)
		d.UsageNext = dashboardURL(next, "usage")
	}
	d.WorkSummary = fmt.Sprintf("%d queued or running, %d verified, %d failed or cancelled", overview.ItemStates["queued"]+overview.ItemStates["running"], overview.ItemStates["verified"], overview.ItemStates["failed"]+overview.ItemStates["cancelled"])
	d.RunSummary = fmt.Sprintf("%d open, %d finished, %d available snapshots", overview.RunStates["open"], overview.RunStates["finished"], overview.RunStates["sealed"])
	d.Tree, d.CatalogQuery = dashboardTree(d, q)
	return d
}

func catalogAPIQuery(c CatalogQuery) url.Values {
	q := url.Values{"group_by": {c.GroupBy}, "limit": {"50"}}
	for k, v := range map[string]string{"distribution": c.Distribution, "arch": c.Arch, "vendor": c.Vendor, "variant": c.Variant, "cursor": c.Cursor} {
		if v != "" {
			q.Set(k, v)
		}
	}
	return q
}

func catalogUsageURL(base url.Values, row Tuple) string {
	q := copyDashboardQuery(base)
	for _, k := range []string{"distribution", "arch", "vendor", "variant", "version", "usage_cursor"} {
		q.Del(k)
	}
	for k, v := range map[string]string{"distribution": row.Distribution, "arch": row.Arch, "vendor": row.Vendor, "variant": row.Variant, "version": row.Version} {
		if v != "" {
			q.Set(k, v)
		}
	}
	return dashboardURL(q, "usage")
}

func dashboardTree(d dashboardPage, q url.Values) ([]dashboardTreeNode, string) {
	cq := catalogPageQuery(q)
	query := catalogAPIQuery(cq)
	nodes := []dashboardTreeNode{}
	for _, row := range d.CatalogRows {
		n := dashboardTreeNode{Label: row.Label, URL: row.URL, UsageURL: catalogUsageURL(q, row.Tuple), ImageVersions: row.ImageVersions, Tags: row.Tags, Downloads: row.Downloads}
		if row.URL != "" {
			child, _ := url.Parse(row.URL)
			n.Query = catalogAPIQuery(catalogPageQuery(child.Query())).Encode()
			n.ParentURL = dashboardURL(copyDashboardQuery(q), "images")
		}
		nodes = append(nodes, n)
	}
	if d.CatalogNext != "" {
		next, _ := url.Parse(d.CatalogNext)
		nq := catalogAPIQuery(catalogPageQuery(next.Query()))
		nodes = append(nodes, dashboardTreeNode{More: true, Label: "More", URL: d.CatalogNext, Query: nq.Encode()})
	}
	base := copyDashboardQuery(q)
	for _, k := range []string{"catalog_distribution", "catalog_arch", "catalog_vendor", "catalog_variant", "catalog_cursor"} {
		base.Del(k)
	}
	parents := []dashboardTreeNode{}
	for _, part := range []struct {
		values map[string]string
		label  string
	}{{map[string]string{"catalog_distribution": cq.Distribution}, cq.Distribution}, {map[string]string{"catalog_arch": cq.Arch}, cq.Arch}, {map[string]string{"catalog_vendor": cq.Vendor, "catalog_variant": cq.Variant}, cq.Vendor + " / " + cq.Variant}} {
		valid := true
		for _, v := range part.values {
			if v == "" {
				valid = false
			}
		}
		if !valid {
			break
		}
		parent := dashboardURL(base, "images")
		for k, v := range part.values {
			base.Set(k, v)
		}
		parents = append(parents, dashboardTreeNode{Label: part.label, URL: dashboardURL(base, "images"), ParentURL: parent, Query: catalogAPIQuery(catalogPageQuery(base)).Encode(), Expanded: true})
	}
	for i := len(parents) - 1; i >= 0; i-- {
		parents[i].Children = nodes
		nodes = []dashboardTreeNode{parents[i]}
	}
	return nodes, query.Encode()
}

func dashboardReadError(err error) (string, int) {
	var e *Error
	if errors.As(err, &e) {
		switch e.Code {
		case "invalid":
			return "This selection is invalid. Choose a group or period again.", http.StatusBadRequest
		case "conflict", "expired":
			return "This selection has expired or changed. Refresh to continue.", http.StatusConflict
		}
	}
	return "Measurements or catalog data are temporarily unavailable. Try again.", http.StatusServiceUnavailable
}

func (h *repositoryHTTP) dashboardHTML(w http.ResponseWriter, r *http.Request) {
	provider := h.opts.Dashboard
	overview, err := provider.DashboardOverview(r.Context())
	if err != nil {
		message, status := dashboardReadError(err)
		w.Header().Set("Cache-Control", "no-store")
		http.Error(w, message, status)
		return
	}
	q := r.URL.Query()
	catalog, catalogErr := provider.DashboardCatalog(r.Context(), catalogPageQuery(q))
	usage, usageErr := provider.DashboardUsage(r.Context(), usagePageQuery(q))
	d := newDashboardPage(overview, catalog, usage, q)
	status := http.StatusOK
	if catalogErr != nil {
		d.CatalogError, status = dashboardReadError(catalogErr)
	}
	if usageErr != nil {
		var usageStatus int
		d.UsageError, usageStatus = dashboardReadError(usageErr)
		if usageStatus > status {
			status = usageStatus
		}
	}
	writeDashboardPage(w, r, d, status)
}

// Reader-only consumers and sealed directory listings retain their old reader
// boundary. Their listing is bounded; usage is unavailable rather than invented.
func legacyDashboardPage(old publicDashboard, r *http.Request) dashboardPage {
	overview := DashboardOverview{DashboardMetadata: DashboardMetadata{Repository: old.Repository, Instance: old.Instance}, Generation: old.Generation, ImageVersions: int64(len(old.Images)), StorageBytes: old.StorageBytes, StorageFiles: int64(old.StorageFiles), NextExpiry: old.NextExpiry, RunStates: map[string]int64{}, ItemStates: map[string]int64{}}
	for k, v := range old.RunStates {
		overview.RunStates[k] = int64(v)
	}
	for k, v := range old.ItemStates {
		overview.ItemStates[k] = int64(v)
	}
	d := newDashboardPage(overview, CatalogPage{GroupBy: "version"}, UsagePage{}, url.Values{})
	d.Enhanced = false
	d.CatalogRowLabel = "versions"
	d.UsageError = "Usage summaries are unavailable for this view."
	offset, _ := strconv.Atoi(r.URL.Query().Get("catalog_offset"))
	if offset < 0 || offset > len(old.Images) {
		offset = 0
	}
	for i, row := range old.Images {
		if i < offset {
			continue
		}
		if i >= offset+50 {
			break
		}
		item := CatalogRow{Tuple: row.Tuple, Tags: row.Tags, ImageVersions: 1}
		for _, file := range row.Downloads {
			item.Downloads = append(item.Downloads, DashboardDownload{Format: file.Format, URL: file.URL, Bytes: file.Bytes})
		}
		d.CatalogRows = append(d.CatalogRows, dashboardCatalogRow{CatalogRow: item, Label: strings.Join([]string{row.Distribution, row.Version, row.Arch, row.Vendor + "/" + row.Variant}, " · ")})
	}
	if offset+50 < len(old.Images) {
		q := url.Values{"catalog_offset": {strconv.Itoa(offset + 50)}}
		d.CatalogNext = r.URL.Path + "?" + q.Encode() + "#images"
	}
	d.CatalogRestart = r.URL.Path + "#images"
	d.CatalogCrumbs = []dashboardLink{{Label: "Image versions", URL: d.CatalogRestart}}
	d.Tree = nil
	for _, row := range d.CatalogRows {
		d.Tree = append(d.Tree, dashboardTreeNode{Label: row.Label, Downloads: row.Downloads, Tags: row.Tags})
	}
	return d
}

func writeDashboardPage(w http.ResponseWriter, r *http.Request, d dashboardPage, status int) {
	var b bytes.Buffer
	if err := dashboardTemplate.Execute(&b, d); err != nil {
		http.Error(w, "Unable to render the dashboard", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Length", strconv.Itoa(b.Len()))
	w.WriteHeader(status)
	if r.Method != http.MethodHead {
		_, _ = w.Write(b.Bytes())
	}
}
