package reposerver

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestCatalogListingMetadata(t *testing.T) {
	first := time.Date(2026, 11, 5, 12, 0, 0, 0, time.FixedZone("offset", 3600))
	second, third := first.Add(time.Hour), first.Add(2*time.Hour)
	base := Tuple{Vendor: "vendor", Variant: "minimal", Arch: "x86_64", Distribution: "debian", Version: "1"}
	shared := FileRef{ID: "shared", Size: 7, Modified: first}
	c := Catalog{Vendors: map[string]string{"default": "vendor", "vendor": "minimal"}, Images: []Image{
		{Tuple: base, Tags: []string{"stable", "latest"}, Files: map[string]FileRef{"tar": shared, "zfs": {Size: 11, Modified: second}}},
		{Tuple: base, Files: map[string]FileRef{"tar": shared}},
		{Tuple: base, Files: map[string]FileRef{"tar": {Size: 13, Modified: third}}},
	}}
	c.Images[1].Version = "2"
	c.Images[2].Arch = "aarch64"
	rows, err := catalogHierarchy(c)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		query CatalogQuery
		bytes int64
		count int
		date  time.Time
	}{
		{CatalogQuery{GroupBy: "distribution"}, 38, 1, third},
		{CatalogQuery{GroupBy: "arch", Distribution: "debian"}, 38, 2, third},
		{CatalogQuery{GroupBy: "variant", Distribution: "debian", Arch: "x86_64"}, 25, 1, second},
		{CatalogQuery{GroupBy: "version", Distribution: "debian", Arch: "x86_64", Vendor: "vendor", Variant: "minimal"}, 25, 2, second},
	} {
		group := rows[hierarchyKey(tc.query)]
		var total int64
		var latest time.Time
		for _, row := range group {
			total += row.Bytes
			if row.LastModified == nil || row.LastModified.Location() != time.UTC {
				t.Fatalf("missing UTC date: %+v", row)
			}
			if row.LastModified.After(latest) {
				latest = *row.LastModified
			}
		}
		if len(group) != tc.count || total != tc.bytes || !latest.Equal(tc.date) {
			t.Fatalf("query=%+v rows=%+v total=%d latest=%s", tc.query, group, total, latest)
		}
	}
	versions := rows[hierarchyKey(CatalogQuery{GroupBy: "version", Distribution: "debian", Arch: "x86_64", Vendor: "vendor", Variant: "minimal"})]
	if versions[0].Bytes != 18 || versions[1].Bytes != 7 || len(versions[0].Downloads) != 2 || len(versions[1].Downloads) != 1 {
		t.Fatal(versions)
	}
	for _, file := range versions[0].Downloads {
		if file.LastModified == nil || !strings.HasPrefix(file.URL, "/v1/vendor/minimal/x86_64/debian/1/") {
			t.Fatal(file)
		}
	}
	if got := versions[0].Downloads[0]; got.Format != "tar" || got.Bytes != 7 || !got.LastModified.Equal(first) {
		t.Fatal(got)
	}
}

func TestCatalogListingUnknownModified(t *testing.T) {
	known := time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)
	for _, files := range []map[string]FileRef{
		{},
		{"tar": {Size: 1}},
		{"tar": {Size: 1, Modified: known}, "zfs": {Size: 0}},
	} {
		c := Catalog{Images: []Image{
			{Tuple: Tuple{Distribution: "debian", Version: "1"}, Files: map[string]FileRef{"tar": {Size: 2, Modified: known}}},
			{Tuple: Tuple{Distribution: "debian", Version: "2"}, Files: files},
			{Tuple: Tuple{Distribution: "debian", Version: "3"}, Files: map[string]FileRef{"tar": {Modified: known}}},
		}}
		rows, err := catalogHierarchy(c)
		if err != nil {
			t.Fatal(err)
		}
		for _, group := range []string{"distribution////", "arch/debian///", "variant/debian///"} {
			if row := rows[group][0]; row.LastModified != nil {
				t.Fatalf("partly unknown date in %s: %+v", group, row)
			}
		}
		version := rows["version/debian///"]
		if version[1].LastModified != nil || version[2].LastModified == nil || version[2].Bytes != 0 {
			t.Fatal(version)
		}
		body, err := json.Marshal(version[1])
		if err != nil || !strings.Contains(string(body), `"last_modified":null`) || strings.Contains(string(body), "0001-01-01") {
			t.Fatalf("body=%s err=%v", body, err)
		}
		for _, download := range version[1].Downloads {
			if files[download.Format].Modified.IsZero() && download.LastModified != nil {
				t.Fatal(download)
			}
		}
	}
	if rows, err := catalogHierarchy(emptyCatalog()); err != nil || len(rows) != 0 {
		t.Fatal(rows, err)
	}
}

func TestCatalogListingSizeIntegrity(t *testing.T) {
	for _, sizes := range [][]int64{{-1}, {math.MaxInt64, 1}} {
		for _, separateImages := range []bool{false, true} {
			c := Catalog{Images: []Image{{Files: map[string]FileRef{}}}}
			for i, size := range sizes {
				if separateImages && i > 0 {
					c.Images = append(c.Images, Image{Tuple: Tuple{Version: "other"}, Files: map[string]FileRef{}})
				}
				c.Images[len(c.Images)-1].Files[[]string{"tar", "zfs"}[i]] = FileRef{Size: size}
			}
			rows, err := catalogHierarchy(c)
			var integrity *Error
			if rows != nil || !errors.As(err, &integrity) || integrity.Code != "integrity" {
				t.Fatalf("sizes=%v separate=%v rows=%v err=%v", sizes, separateImages, rows, err)
			}
		}
	}
	rows, err := catalogHierarchy(Catalog{Images: []Image{{Files: map[string]FileRef{"tar": {Size: math.MaxInt64}, "zfs": {Size: 0}}}}})
	if err != nil || rows["distribution////"][0].Bytes != math.MaxInt64 {
		t.Fatal(rows, err)
	}
}

func TestDashboardCatalogMetadataBeforePagination(t *testing.T) {
	s, clock := testStore(t)
	run := begin(t, s, "metadata", "one", "two")
	uploadItem(t, s, run.Key, "one", "1", "one")
	*clock = clock.Add(time.Minute)
	uploadItem(t, s, run.Key, "two", "2", "twotwo")
	call(t, s, "producer", "finish", run.Key, map[string]any{}, "")
	publish(t, s, run.Key, "one", "two")
	r := NewStoreDashboardReader(s, "test", "one", nil)
	for _, query := range []CatalogQuery{
		{GroupBy: "distribution", Limit: 1},
		{GroupBy: "arch", Distribution: "debian", Limit: 1},
		{GroupBy: "variant", Distribution: "debian", Arch: "x86_64", Limit: 1},
	} {
		page, err := r.DashboardCatalog(context.Background(), query)
		if err != nil || len(page.Rows) != 1 || page.Rows[0].Bytes != 9 || page.Rows[0].ImageVersions != 2 || page.Rows[0].LastModified == nil || !page.Rows[0].LastModified.Equal(*clock) {
			t.Fatal(query, page, err)
		}
	}
	query := CatalogQuery{GroupBy: "version", Distribution: "debian", Arch: "x86_64", Vendor: "vendor", Variant: "minimal", Limit: 1}
	first, err := r.DashboardCatalog(context.Background(), query)
	if err != nil || len(first.Rows) != 1 || first.Rows[0].Bytes != 3 || first.NextCursor == "" {
		t.Fatal(first, err)
	}
	query.Cursor = first.NextCursor
	second, err := r.DashboardCatalog(context.Background(), query)
	if err != nil || len(second.Rows) != 1 || second.Rows[0].Bytes != 6 || second.NextCursor != "" {
		t.Fatal(second, err)
	}
	h := NewHTTPHandler(s, HTTPOptions{Repository: "test"})
	response := requestHTTP(h, "GET", "/dashboard/api/catalog?group_by=version&distribution=debian&arch=x86_64&vendor=vendor&variant=minimal&limit=1", nil)
	var page CatalogPage
	if err := json.Unmarshal(response.Body.Bytes(), &page); err != nil || response.Code != 200 || len(page.Rows) != 1 || page.Rows[0].Bytes != 3 || page.Rows[0].Downloads[0].LastModified == nil {
		t.Fatal(response.Code, response.Body.String(), err)
	}
}

func TestCatalogInvalidMetadataNotCached(t *testing.T) {
	s, _ := testStore(t)
	begin(t, s, "corrupt-metadata")
	// Simulate corrupt persisted metadata without creating any payload files.
	c := Catalog{Images: []Image{{Files: map[string]FileRef{"tar": {Size: math.MaxInt64}, "zfs": {Size: 1}}}}}
	if _, err := s.db.Exec("UPDATE catalogs SET document=? WHERE id=(SELECT generation FROM repositories WHERE id='test')", encode(c)); err != nil {
		t.Fatal(err)
	}
	_, err := s.catalogSnapshot(context.Background(), "test", "")
	var integrity *Error
	if !errors.As(err, &integrity) || integrity.Code != "integrity" || len(s.catalogs) != 0 || s.cacheBytes != 0 {
		t.Fatalf("err=%v cache=%d bytes=%d", err, len(s.catalogs), s.cacheBytes)
	}
}

func TestDashboardCatalogAncestors(t *testing.T) {
	s, clock := testStore(t)
	begin(t, s, "ancestor-metadata")
	selected := Tuple{Distribution: "z-distribution", Arch: "z-arch", Vendor: "z-vendor", Variant: "minimal", Version: "1"}
	c := Catalog{Vendors: map[string]string{"default": "z-vendor", "z-vendor": "minimal"}}
	for i := range 100 {
		for _, tuple := range []Tuple{
			{Distribution: fmt.Sprintf("distribution-%03d", i), Arch: "x86_64", Vendor: "vendor", Variant: "minimal", Version: "1"},
			{Distribution: selected.Distribution, Arch: fmt.Sprintf("arch-%03d", i), Vendor: "vendor", Variant: "minimal", Version: "1"},
			{Distribution: selected.Distribution, Arch: selected.Arch, Vendor: fmt.Sprintf("vendor-%03d", i), Variant: "minimal", Version: "1"},
		} {
			c.Images = append(c.Images, Image{Tuple: tuple, Files: map[string]FileRef{"tar": {ID: "shared", Format: "tar", Size: 1, Modified: *clock}}})
		}
	}
	c.Images = append(c.Images, Image{Tuple: selected, Files: map[string]FileRef{
		"tar": {ID: "shared", Format: "tar", Size: 7, Modified: *clock},
		"zfs": {ID: "stream", Format: "zfs", Size: 11, Modified: *clock},
	}})
	selected.Version = "2"
	c.Images = append(c.Images, Image{Tuple: selected, Files: map[string]FileRef{"tar": {ID: "older", Format: "tar", Size: 13}}})
	// Persist metadata only: a listing must not open or stat these payloads.
	if _, err := s.db.Exec("UPDATE catalogs SET document=? WHERE id=(SELECT generation FROM repositories WHERE id='test')", encode(c)); err != nil {
		t.Fatal(err)
	}
	r := NewStoreDashboardReader(s, "test", "one", nil)
	root, err := r.DashboardCatalog(context.Background(), CatalogQuery{Limit: 100})
	if err != nil || root.Ancestors == nil || len(root.Ancestors) != 0 || root.NextCursor == "" || root.Rows[99].Distribution == selected.Distribution {
		t.Fatal(root, err)
	}
	if body := string(encode(root)); !strings.Contains(body, `"ancestors":[]`) {
		t.Fatal(body)
	}
	for depth, query := range []CatalogQuery{
		{GroupBy: "arch", Distribution: selected.Distribution, Limit: 100},
		{GroupBy: "variant", Distribution: selected.Distribution, Arch: selected.Arch, Limit: 100},
		{GroupBy: "version", Distribution: selected.Distribution, Arch: selected.Arch, Vendor: selected.Vendor, Variant: selected.Variant, Limit: 1},
	} {
		page, err := r.DashboardCatalog(context.Background(), query)
		if err != nil || len(page.Ancestors) != depth+1 || page.NextCursor == "" || page.Generation != root.Generation {
			t.Fatal(query, page, err)
		}
		for i, ancestor := range page.Ancestors {
			wantTuple := []Tuple{{Distribution: selected.Distribution}, {Distribution: selected.Distribution, Arch: selected.Arch}, {Distribution: selected.Distribution, Arch: selected.Arch, Vendor: selected.Vendor, Variant: selected.Variant}}[i]
			if ancestor.Tuple != wantTuple || ancestor.Bytes != []int64{231, 131, 31}[i] || ancestor.ImageVersions != []int64{202, 102, 2}[i] || ancestor.LastModified != nil {
				t.Fatal(ancestor)
			}
		}
		query.Cursor = page.NextCursor
		next, err := r.DashboardCatalog(context.Background(), query)
		if err != nil || !reflect.DeepEqual(page.Ancestors, next.Ancestors) {
			t.Fatal(next, err)
		}
		query.Cursor, query.Limit = "", 50
		otherLimit, err := r.DashboardCatalog(context.Background(), query)
		if err != nil || !reflect.DeepEqual(page.Ancestors, otherLimit.Ancestors) {
			t.Fatal(otherLimit, err)
		}
	}
	missing, err := r.DashboardCatalog(context.Background(), CatalogQuery{GroupBy: "variant", Distribution: selected.Distribution, Arch: "absent"})
	if err != nil || len(missing.Rows) != 0 || len(missing.Ancestors) != 1 || missing.Ancestors[0].Distribution != selected.Distribution {
		t.Fatal(missing, err)
	}
	if _, err := s.db.Exec("INSERT INTO catalogs(id,repository,document,modified,retain_until) SELECT 'replacement',repository,document,modified,retain_until FROM catalogs WHERE id=?", root.Generation); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec("UPDATE repositories SET generation='replacement' WHERE id='test'"); err != nil {
		t.Fatal(err)
	}
	_, err = r.DashboardCatalog(context.Background(), CatalogQuery{Limit: 100, Cursor: root.NextCursor})
	var conflict *Error
	if !errors.As(err, &conflict) || conflict.Code != "conflict" {
		t.Fatal(err)
	}
}
