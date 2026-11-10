package reposerver

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

// Configure the existing overview method once so HTML and API callers use the
// same presentation identity, independently of the stable repository key.
type configuredDashboardReader struct {
	DashboardReader
	displayName, purpose string
}

func (d configuredDashboardReader) DashboardOverview(ctx context.Context) (DashboardOverview, error) {
	v, err := d.DashboardReader.DashboardOverview(ctx)
	v.DisplayName, v.Purpose = d.displayName, d.purpose
	return v, err
}

func (h *repositoryHTTP) dashboardAPI(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if h.opts.Dashboard == nil {
		http.Error(w, "Dashboard unavailable", 503)
		return
	}
	values, err := parseDashboardQuery(r)
	if err != nil {
		http.Error(w, "Invalid query", 400)
		return
	}
	limit := 0
	if v := values["limit"]; v != "" {
		limit, err = strconv.Atoi(v)
		if err != nil || limit < 1 || limit > 100 {
			http.Error(w, "Invalid limit", 400)
			return
		}
	}
	var result any
	switch r.URL.Path {
	case "/dashboard/api/overview":
		if len(values) != 0 {
			http.Error(w, "Unknown overview filter", 400)
			return
		}
		result, err = h.opts.Dashboard.DashboardOverview(r.Context())
	case "/dashboard/api/catalog":
		for k := range values {
			if k == "period" || k == "version" {
				http.Error(w, "Unknown catalog filter", 400)
				return
			}
		}
		result, err = h.opts.Dashboard.DashboardCatalog(r.Context(), CatalogQuery{GroupBy: values["group_by"], Distribution: values["distribution"], Arch: values["arch"], Vendor: values["vendor"], Variant: values["variant"], Cursor: values["cursor"], Limit: limit})
	case "/dashboard/api/usage":
		result, err = h.opts.Dashboard.DashboardUsage(r.Context(), UsageQuery{Period: values["period"], GroupBy: values["group_by"], Distribution: values["distribution"], Arch: values["arch"], Vendor: values["vendor"], Variant: values["variant"], Version: values["version"], Cursor: values["cursor"], Limit: limit})
	default:
		http.NotFound(w, r)
		return
	}
	if err != nil {
		status := 503
		message := "Dashboard unavailable"
		var e *Error
		if errors.As(err, &e) {
			switch e.Code {
			case "invalid":
				status = 400
				message = e.Message
			case "conflict":
				status = 409
				message = e.Message
			case "bounded":
				message = e.Message
			}
		}
		http.Error(w, message, status)
		return
	}
	body, err := json.Marshal(result)
	if err != nil {
		http.Error(w, "Dashboard unavailable", 503)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	if r.Method != "HEAD" {
		_, _ = w.Write(body)
	}
}
func parseDashboardQuery(r *http.Request) (map[string]string, error) {
	allowed := map[string]bool{}
	for _, k := range strings.Fields("period group_by distribution arch vendor variant version cursor limit") {
		allowed[k] = true
	}
	out := map[string]string{}
	values, err := r.URL.Query(), error(nil)
	if r.URL.RawQuery != "" {
		values, err = url.ParseQuery(r.URL.RawQuery)
	}
	if err != nil {
		return nil, err
	}
	for k, v := range values {
		if !allowed[k] || len(v) != 1 || len(v[0]) > 2048 {
			return nil, problem("invalid", "unknown or repeated filter")
		}
		out[k] = v[0]
	}
	return out, nil
}
