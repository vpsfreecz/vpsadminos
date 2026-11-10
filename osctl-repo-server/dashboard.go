package reposerver

import (
	"encoding/json"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

type downloadLink struct {
	Format string `json:"format"`
	URL    string `json:"url"`
	Bytes  int64  `json:"bytes"`
}

type catalogRow struct {
	Tuple
	Tags      []string       `json:"tags"`
	Downloads []downloadLink `json:"downloads"`
}

type publicDashboard struct {
	Repository   string            `json:"repository"`
	Instance     string            `json:"instance"`
	Generation   string            `json:"generation"`
	Scope        string            `json:"scope"`
	Images       []catalogRow      `json:"images"`
	StorageBytes int64             `json:"storage_bytes"`
	StorageFiles int64             `json:"storage_files"`
	RunStates    map[string]int    `json:"run_states"`
	ItemStates   map[string]int    `json:"item_states"`
	NextExpiry   *time.Time        `json:"next_expiry,omitempty"`
	Statistics   []DailyStatistic  `json:"statistics"`
	Measurement  MeasurementHealth `json:"measurement"`
}

func (h *repositoryHTTP) dashboard(w http.ResponseWriter, r *http.Request, run, p string) {
	if (p == "/" || p == "/v1/") && run == "" && h.opts.Dashboard != nil {
		h.dashboardHTML(w, r)
		return
	}
	view, err := h.reader.Catalog(r.Context(), h.opts.Repository, run)
	if err != nil {
		h.readerError(w, r, err)
		return
	}
	filter := catalogDirectory(p, view.Catalog)
	storage, err := h.reader.Storage(r.Context(), h.opts.Repository)
	if err != nil {
		h.readerError(w, r, err)
		return
	}
	d := publicDashboard{Repository: view.Repository, Instance: h.opts.Instance, Generation: view.Generation, Scope: view.Scope,
		Images: []catalogRow{}, StorageBytes: storage.Bytes, StorageFiles: storage.Files, RunStates: map[string]int{}, ItemStates: map[string]int{}, Statistics: []DailyStatistic{}}
	for _, summary := range storage.Runs {
		d.RunStates[summary.State]++
		for _, item := range summary.Items {
			d.ItemStates[item.State]++
		}
		if summary.State != "expired" && !summary.Expires.IsZero() && (d.NextExpiry == nil || summary.Expires.Before(*d.NextExpiry)) {
			expires := summary.Expires
			d.NextExpiry = &expires
		}
	}
	prefix := ""
	if run != "" {
		prefix = "/runs/" + url.PathEscape(run)
	}
	for _, img := range view.Catalog.Images {
		row := catalogRow{Tuple: img.Tuple, Tags: append([]string{}, img.Tags...), Downloads: []downloadLink{}}
		for format, ref := range img.Files {
			u := prefix + "/v1/" + escapedTuplePath(img.Tuple) + "/" + formatFilename(format)
			if formatFilename(format) == "" {
				continue
			}
			if strings.HasPrefix(p, "/v1/") && !strings.HasPrefix("/v1/"+tuplePath(img.Tuple)+"/"+formatFilename(format), filter) {
				continue
			}
			row.Downloads = append(row.Downloads, downloadLink{format, u, ref.Size})
		}
		if len(row.Downloads) > 0 {
			sort.Slice(row.Downloads, func(i, j int) bool { return row.Downloads[i].Format < row.Downloads[j].Format })
			sort.Strings(row.Tags)
			d.Images = append(d.Images, row)
		}
	}
	if strings.HasPrefix(p, "/v1/") && len(d.Images) == 0 && p != "/v1/" {
		http.NotFound(w, r)
		return
	}
	sort.Slice(d.Images, func(i, j int) bool { return httpTupleLess(d.Images[i].Tuple, d.Images[j].Tuple) })
	if h.opts.Observer != nil {
		d.Statistics = h.opts.Observer.Statistics()
		d.Measurement = h.opts.Observer.Health()
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'")
	var body []byte
	if p == "/dashboard.json" {
		w.Header().Set("Content-Type", "application/json")
		body, err = json.Marshal(d)
	} else {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		var b strings.Builder
		err = dashboardTemplate.Execute(&b, legacyDashboardPage(d, r))
		body = []byte(b.String())
	}
	if err != nil {
		h.readerError(w, r, err)
		return
	}
	w.Header().Set("Content-Length", strconvLen(len(body)))
	if r.Method != "HEAD" {
		_, _ = w.Write(body)
	}
}

func catalogDirectory(p string, c Catalog) string {
	parts := strings.Split(strings.Trim(strings.TrimPrefix(p, "/v1/"), "/"), "/")
	if len(parts) > 0 && parts[0] == "default" {
		parts[0] = c.Vendors["default"]
	}
	if len(parts) > 1 && parts[1] == "default" {
		parts[1] = c.Vendors[parts[0]]
	}
	if len(parts) == 5 {
		for _, img := range c.Images {
			if img.Vendor == parts[0] && img.Variant == parts[1] && img.Arch == parts[2] && img.Distribution == parts[3] {
				for _, tag := range img.Tags {
					if tag == parts[4] {
						parts[4] = img.Version
						break
					}
				}
			}
		}
	}
	if p == "/v1/" {
		return p
	}
	return "/v1/" + strings.Join(parts, "/") + "/"
}

func escapedTuplePath(t Tuple) string {
	parts := []string{t.Vendor, t.Variant, t.Arch, t.Distribution, t.Version}
	for i, p := range parts {
		parts[i] = url.PathEscape(p)
	}
	return strings.Join(parts, "/")
}

func strconvLen(n int) string { // keep the response length identical for GET/HEAD
	return strconv.Itoa(n)
}
