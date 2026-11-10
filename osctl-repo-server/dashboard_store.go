package reposerver

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strings"
	"time"
)

type cachedCatalog struct {
	view  CatalogView
	paths map[string]struct {
		image  Image
		format string
	}
	index     []byte
	etag      string
	size      int
	hierarchy map[string][]CatalogRow
}

func (c *cachedCatalog) resolve(p string) (Image, string, error) {
	v, ok := c.paths[p]
	if !ok {
		return Image{}, "", problem("not_found", "image not found")
	}
	return v.image, v.format, nil
}
func (s *Store) catalogVisible(ctx context.Context, q querier, repo, key, generation string) error {
	if key != "" {
		r, e := loadRun(ctx, q, key, repo)
		if e != nil {
			return e
		}
		if r.State == "expired" || !r.Expires.After(s.now()) {
			return problem("expired", "run lease expired")
		}
		if r.State != "sealed" {
			return problem("not_ready", "run not sealed")
		}
		if r.Generation != generation {
			return problem("conflict", "catalog changed")
		}
		return nil
	}
	var got string
	if e := q.QueryRowContext(ctx, "SELECT generation FROM repositories WHERE id=?", repo).Scan(&got); e != nil {
		if e == sql.ErrNoRows {
			return problem("not_found", "repository not found")
		}
		return e
	}
	if got != generation {
		return problem("conflict", "catalog changed")
	}
	return nil
}
func (s *Store) catalogSnapshot(ctx context.Context, repo, key string) (*cachedCatalog, error) {
	var gen string
	if key == "" {
		if e := s.reads.QueryRowContext(ctx, "SELECT generation FROM repositories WHERE id=?", repo).Scan(&gen); e != nil {
			if e == sql.ErrNoRows {
				return nil, problem("not_found", "repository not found")
			}
			return nil, e
		}
	} else {
		r, e := loadRun(ctx, s.reads, key, repo)
		if e != nil {
			return nil, e
		}
		if r.State == "expired" || !r.Expires.After(s.now()) {
			return nil, problem("expired", "run lease expired")
		}
		if r.State != "sealed" {
			return nil, problem("not_ready", "run not sealed")
		}
		gen = r.Generation
	}
	s.cacheMu.Lock()
	defer s.cacheMu.Unlock()
	if c := s.catalogs[gen]; c != nil {
		out := *c
		out.view.Scope = "public"
		out.view.RunKey = ""
		if key != "" {
			out.view.Scope = "run"
			out.view.RunKey = key
		}
		return &out, nil
	}
	view, e := loadCatalog(ctx, s.reads, gen)
	if e != nil {
		return nil, e
	}
	c := &cachedCatalog{view: view, paths: map[string]struct {
		image  Image
		format string
	}{}}
	// Canonical paths, defaults and tags use the same immutable generation.
	for _, im := range view.Catalog.Images {
		vendors := []string{im.Vendor}
		if view.Catalog.Vendors["default"] == im.Vendor {
			vendors = append(vendors, "default")
		}
		variants := []string{im.Variant}
		if view.Catalog.Vendors[im.Vendor] == im.Variant {
			variants = append(variants, "default")
		}
		versions := append([]string{im.Version}, im.Tags...)
		for format := range im.Files {
			for _, v := range vendors {
				for _, variant := range variants {
					for _, version := range versions {
						p := strings.Join([]string{v, variant, im.Arch, im.Distribution, version, filename(format)}, "/")
						if _, exists := c.paths[p]; exists {
							continue
						}
						c.paths[p] = struct {
							image  Image
							format string
						}{im, format}
					}
				}
			}
		}
	}
	c.hierarchy = catalogHierarchy(view.Catalog)
	c.index, e = nativeIndex(view.Catalog)
	if e != nil {
		return nil, e
	}
	sum := sha256.Sum256(c.index)
	c.etag = fmt.Sprintf(`"%x"`, sum)
	c.size = len(c.index)
	for p := range c.paths {
		c.size += len(p) + 256
	}
	for key, rows := range c.hierarchy {
		c.size += len(key)
		for _, row := range rows {
			c.size += len(encode(row)) + 128
		}
	}
	// Two generations and sixty-four MiB, independent of the catalog's own quota.
	if c.size <= 64<<20 {
		if len(s.catalogs) >= 2 || s.cacheBytes+c.size > 64<<20 {
			s.catalogs = map[string]*cachedCatalog{}
			s.cacheBytes = 0
		}
		s.catalogs[gen] = c
		s.cacheBytes += c.size
	}
	out := *c
	if key != "" {
		out.view.Scope = "run"
		out.view.RunKey = key
	}
	return &out, nil
}

// StoreDashboardReader binds the public dashboard to one repository/instance.
type StoreDashboardReader struct {
	store                *Store
	repository, instance string
	observer             *HTTPObserver
	summaryMu            chan struct{}
	summary              DashboardOverview
	summaryUntil         time.Time
	usage                usageResultCache
}

func NewStoreDashboardReader(s *Store, repository, instance string, observer *HTTPObserver) *StoreDashboardReader {
	return &StoreDashboardReader{store: s, repository: repository, instance: instance, observer: observer, summaryMu: make(chan struct{}, 1)}
}
func (d *StoreDashboardReader) metadata() DashboardMetadata {
	return DashboardMetadata{1, d.repository, d.instance, d.store.now()}
}
func (d *StoreDashboardReader) health() MeasurementHealth {
	if d.observer != nil {
		return d.observer.Health()
	}
	return MeasurementHealth{}
}
func (d *StoreDashboardReader) DashboardOverview(ctx context.Context) (DashboardOverview, error) {
	select {
	case d.summaryMu <- struct{}{}:
		defer func() { <-d.summaryMu }()
	case <-ctx.Done():
		return DashboardOverview{}, ctx.Err()
	}
	if err := d.store.reads.PingContext(ctx); err != nil {
		return DashboardOverview{}, err
	}
	now := d.store.now()
	if now.Before(d.summaryUntil) {
		v := d.summary
		v.GeneratedAt = now
		v.Measurement = d.health()
		return v, nil
	}
	tx, e := d.store.reads.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if e != nil {
		return DashboardOverview{}, e
	}
	defer tx.Rollback()
	v := DashboardOverview{DashboardMetadata: d.metadata(), RunStates: map[string]int64{}, ItemStates: map[string]int64{}, Measurement: d.health()}
	if e = tx.QueryRowContext(ctx, `SELECT repositories.generation,json_array_length(catalogs.document,'$.images') FROM repositories JOIN catalogs ON catalogs.id=repositories.generation WHERE repositories.id=?`, d.repository).Scan(&v.Generation, &v.ImageVersions); e != nil {
		return v, e
	}
	if e = tx.QueryRowContext(ctx, "SELECT count(*),coalesce(sum(size),0) FROM files").Scan(&v.StorageFiles, &v.StorageBytes); e != nil {
		return v, e
	}
	for _, spec := range []struct {
		sql    string
		target map[string]int64
	}{{`SELECT json_extract(document,'$.state'),count(*) FROM runs WHERE repository=? GROUP BY 1`, v.RunStates}, {`SELECT json_extract(items.value,'$.state'),count(*) FROM runs,json_each(runs.document,'$.items') items WHERE repository=? GROUP BY 1`, v.ItemStates}} {
		rows, err := tx.QueryContext(ctx, spec.sql, d.repository)
		if err != nil {
			return v, err
		}
		for rows.Next() {
			var k string
			var n int64
			if err = rows.Scan(&k, &n); err != nil {
				rows.Close()
				return v, err
			}
			spec.target[k] = n
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return v, err
		}
	}
	var expiry sql.NullString
	if e = tx.QueryRowContext(ctx, `SELECT min(json_extract(document,'$.expires')) FROM runs WHERE repository=? AND json_extract(document,'$.state')!='expired'`, d.repository).Scan(&expiry); e != nil {
		return v, e
	}
	if expiry.Valid {
		t, err := time.Parse(time.RFC3339Nano, expiry.String)
		if err != nil {
			return v, err
		}
		v.NextExpiry = &t
	}
	if e = tx.Commit(); e != nil {
		return v, e
	}
	d.summary = v
	d.summaryUntil = now.Add(2 * time.Second)
	return v, nil
}

type dashboardCursor struct {
	Kind, Binding, Revision string
	Offset                  int
	End                     time.Time
}

func cursorBinding(v any) string { sum := sha256.Sum256(encode(v)); return fmt.Sprintf("%x", sum) }
func parseCursor(raw, kind, binding, revision string) (dashboardCursor, error) {
	if raw == "" {
		return dashboardCursor{Kind: kind, Binding: binding, Revision: revision}, nil
	}
	c, e := decodeDashboardCursor(raw, kind, binding)
	if e != nil {
		return c, e
	}
	if c.Revision != revision {
		return c, problem("conflict", "snapshot changed; restart pagination")
	}
	return c, nil
}

func decodeDashboardCursor(raw, kind, binding string) (dashboardCursor, error) {
	var c dashboardCursor
	b, e := base64.RawURLEncoding.DecodeString(raw)
	if e != nil || len(b) > 2048 {
		return c, problem("invalid", "invalid cursor")
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if dec.Decode(&c) != nil || c.Kind != kind || c.Binding != binding || c.Offset < 0 || c.Offset > 1000000 {
		return c, problem("invalid", "invalid cursor")
	}
	var trailing any
	if dec.Decode(&trailing) != io.EOF {
		return c, problem("invalid", "invalid cursor")
	}
	return c, nil
}
func encodeCursor(c dashboardCursor) string { return base64.RawURLEncoding.EncodeToString(encode(c)) }
func pageLimit(n int) (int, error) {
	if n == 0 {
		return 50, nil
	}
	if n < 1 || n > 100 {
		return 0, problem("invalid", "limit must be between 1 and 100")
	}
	return n, nil
}
func validFilters(values ...string) error {
	for _, v := range values {
		if v != "" && (!component.MatchString(v) || v == "." || v == "..") {
			return problem("invalid", "invalid filter")
		}
	}
	return nil
}
func (d *StoreDashboardReader) DashboardCatalog(ctx context.Context, q CatalogQuery) (CatalogPage, error) {
	if q.GroupBy == "" {
		q.GroupBy = "distribution"
	}
	limit, e := pageLimit(q.Limit)
	if e != nil {
		return CatalogPage{}, e
	}
	if e = validFilters(q.Distribution, q.Arch, q.Vendor, q.Variant); e != nil {
		return CatalogPage{}, e
	}
	if !contains([]string{"distribution", "arch", "variant", "version"}, q.GroupBy) {
		return CatalogPage{}, problem("invalid", "unknown catalog grouping")
	}
	valid := false
	switch q.GroupBy {
	case "distribution":
		valid = q.Distribution == "" && q.Arch == "" && q.Vendor == "" && q.Variant == ""
	case "arch":
		valid = q.Distribution != "" && q.Arch == "" && q.Vendor == "" && q.Variant == ""
	case "variant":
		valid = q.Distribution != "" && q.Arch != "" && q.Vendor == "" && q.Variant == ""
	case "version":
		valid = q.Distribution != "" && q.Arch != "" && q.Vendor != "" && q.Variant != ""
	}
	if !valid {
		return CatalogPage{}, problem("invalid", "missing parents or extra child filters")
	}

	cached, e := d.store.catalogSnapshot(ctx, d.repository, "")
	if e != nil {
		return CatalogPage{}, e
	}
	binding := q
	binding.Cursor = ""
	binding.Limit = limit
	c, e := parseCursor(q.Cursor, "catalog", cursorBinding(binding), cached.view.Generation)
	if e != nil {
		return CatalogPage{}, e
	}
	rows := cached.hierarchy[hierarchyKey(q)]
	if c.Offset > len(rows) {
		return CatalogPage{}, problem("invalid", "invalid cursor offset")
	}
	v := CatalogPage{DashboardMetadata: d.metadata(), Generation: cached.view.Generation, GroupBy: q.GroupBy, Rows: []CatalogRow{}}
	end := c.Offset + limit
	if end > len(rows) {
		end = len(rows)
	}
	v.Rows = append(v.Rows, rows[c.Offset:end]...)
	if end < len(rows) {
		c.Offset = end
		v.NextCursor = encodeCursor(c)
	}
	return v, nil
}

func hierarchyKey(q CatalogQuery) string {
	return strings.Join([]string{q.GroupBy, q.Distribution, q.Arch, q.Vendor, q.Variant}, "/")
}
func catalogHierarchy(c Catalog) map[string][]CatalogRow {
	groups := map[string]map[string]*CatalogRow{}
	for _, im := range c.Images {
		entries := []struct {
			q CatalogQuery
			t Tuple
		}{
			{CatalogQuery{GroupBy: "distribution"}, Tuple{Distribution: im.Distribution}},
			{CatalogQuery{GroupBy: "arch", Distribution: im.Distribution}, Tuple{Distribution: im.Distribution, Arch: im.Arch}},
			{CatalogQuery{GroupBy: "variant", Distribution: im.Distribution, Arch: im.Arch}, Tuple{Distribution: im.Distribution, Arch: im.Arch, Vendor: im.Vendor, Variant: im.Variant}},
			{CatalogQuery{GroupBy: "version", Distribution: im.Distribution, Arch: im.Arch, Vendor: im.Vendor, Variant: im.Variant}, im.Tuple},
		}
		for _, entry := range entries {
			key := hierarchyKey(entry.q)
			if groups[key] == nil {
				groups[key] = map[string]*CatalogRow{}
			}
			row := groups[key][entry.t.Key()]
			if row == nil {
				row = &CatalogRow{Tuple: entry.t}
				groups[key][entry.t.Key()] = row
			}
			row.ImageVersions++
			if entry.q.GroupBy == "version" {
				row.Tags = append([]string{}, im.Tags...)
				sort.Strings(row.Tags)
				row.Downloads = []DashboardDownload{}
				for _, format := range sortedKeys(im.Files) {
					ref := im.Files[format]
					row.Downloads = append(row.Downloads, DashboardDownload{format, "/v1/" + escapedTuplePath(im.Tuple) + "/" + filename(format), ref.Size})
				}
			}
		}
	}
	out := map[string][]CatalogRow{}
	for group, rows := range groups {
		for _, key := range sortedKeys(rows) {
			out[group] = append(out[group], *rows[key])
		}
	}
	return out
}
