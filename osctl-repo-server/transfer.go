package reposerver

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// GenerationManifest uses stable external IDs only, and excludes all private
// run, source-input, access-log, pending-upload and SQLite implementation state.
type GenerationManifest struct {
	Schema      int                `json:"schema"`
	Repository  string             `json:"repository"`
	Generation  string             `json:"generation"`
	Catalog     Catalog            `json:"catalog"`
	IndexSHA256 string             `json:"index_sha256"`
	Paths       map[string]string  `json:"paths"`
	Files       map[string]FileRef `json:"files"`
}
type TransferParams struct {
	Path         string `json:"path"`
	Generation   string `json:"generation,omitempty"`
	LeaseSeconds int64  `json:"lease_seconds,omitempty"`
}

func safeRegular(root, relative string) (string, os.FileInfo, error) {
	if filepath.IsAbs(relative) || filepath.Clean(relative) != relative || relative == ".." || strings.HasPrefix(relative, "../") {
		return "", nil, problem("invalid", "unsafe payload path")
	}
	base, e := filepath.Abs(root)
	if e != nil {
		return "", nil, e
	}
	rootInfo, e := os.Lstat(base)
	if e != nil {
		return "", nil, e
	}
	if !rootInfo.IsDir() || rootInfo.Mode()&os.ModeSymlink != 0 {
		return "", nil, problem("integrity", "transfer root is not a real directory")
	}
	current := base
	var info os.FileInfo
	for _, part := range strings.Split(relative, string(filepath.Separator)) {
		current = filepath.Join(current, part)
		info, e = os.Lstat(current)
		if e != nil {
			return "", nil, e
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return "", nil, problem("integrity", "payload path contains symlink")
		}
	}
	if !info.Mode().IsRegular() {
		return "", nil, problem("integrity", "payload is not regular")
	}
	return current, info, nil
}
func checkSelection(ctx context.Context, tx *sql.Tx, repo, wanted string) error {
	var current string
	e := tx.QueryRowContext(ctx, "SELECT generation FROM repositories WHERE id=?", repo).Scan(&current)
	if errors.Is(e, sql.ErrNoRows) && wanted == "" {
		return nil
	}
	if e != nil {
		return e
	}
	if current == wanted {
		return nil
	}
	if wanted == "" {
		v, e := loadCatalog(ctx, tx, current)
		if e == nil && len(v.Catalog.Images) == 0 {
			return nil
		}
	}
	return problem("conflict", "import target generation changed")
}
func (s *Store) transfer(ctx context.Context, tx *sql.Tx, q Request, _ io.Reader) (any, error) {
	var p TransferParams
	if e := params(q.Params, &p); e != nil {
		return nil, e
	}
	if !filepath.IsAbs(p.Path) {
		return nil, problem("invalid", "absolute transfer path required")
	}
	switch q.Operation {
	case "export-legacy":
		v, e := s.catalog(ctx, tx, q.Repository, "")
		if e != nil {
			return nil, e
		}
		if e = s.verifyCatalog(ctx, tx, v.Catalog); e != nil {
			return nil, e
		}
		if e = os.Mkdir(p.Path, 0700); e != nil {
			return nil, e
		}
		schemaRoot := filepath.Join(p.Path, "v1")
		if e = os.Mkdir(schemaRoot, 0755); e != nil {
			return nil, e
		}
		for _, im := range v.Catalog.Images {
			directory := filepath.Join(schemaRoot, im.Key())
			if e = os.MkdirAll(directory, 0755); e != nil {
				return nil, e
			}
			for format, ref := range im.Files {
				_, source, e := fileRef(ctx, tx, ref.ID)
				if e != nil {
					return nil, e
				}
				if e = copyVerified(source, filepath.Join(directory, filename(format)), ref); e != nil {
					return nil, e
				}
			}
			if e = syncDir(directory); e != nil {
				return nil, e
			}
		}
		links := map[string]string{}
		if v.Catalog.Vendors["default"] != "" {
			links["default"] = v.Catalog.Vendors["default"]
		}
		for vendor, variant := range v.Catalog.Vendors {
			if vendor != "default" {
				links[filepath.Join(vendor, "default")] = variant
			}
		}
		for _, im := range v.Catalog.Images {
			for _, tag := range im.Tags {
				if tag != im.Version {
					links[filepath.Join(im.Vendor, im.Variant, im.Arch, im.Distribution, tag)] = im.Version
				}
			}
		}
		for relative, target := range links {
			if e = os.Symlink(target, filepath.Join(schemaRoot, relative)); e != nil {
				return nil, e
			}
		}
		if e = writeDurable(filepath.Join(schemaRoot, "INDEX.json"), encode(V1Index(v.Catalog))); e != nil {
			return nil, e
		}
		if e = syncDir(schemaRoot); e != nil {
			return nil, e
		}
		if e = syncDir(p.Path); e != nil {
			return nil, e
		}
		if e = syncDir(filepath.Dir(p.Path)); e != nil {
			return nil, e
		}
		return map[string]any{"repository": q.Repository, "generation": v.Generation, "index": V1Index(v.Catalog)}, nil
	case "import-legacy":
		if e := checkSelection(ctx, tx, q.Repository, p.Generation); e != nil {
			return nil, e
		}
		indexPath, _, e := safeRegular(p.Path, "v1/INDEX.json")
		if e != nil {
			return nil, e
		}
		data, e := os.ReadFile(indexPath)
		if e != nil {
			return nil, e
		}
		var native struct {
			Vendors map[string]string `json:"vendors"`
			Images  []struct {
				Tuple
				Tags  []string          `json:"tags"`
				Image map[string]string `json:"image"`
			} `json:"images"`
		}
		if e = json.Unmarshal(data, &native); e != nil {
			return nil, problem("integrity", "invalid legacy index")
		}
		c := Catalog{Vendors: native.Vendors, Images: []Image{}}
		for _, legacy := range native.Images {
			if !legacy.Tuple.valid() {
				return nil, problem("integrity", "invalid imported tuple")
			}
			im := Image{Tuple: legacy.Tuple, Tags: legacy.Tags, Files: map[string]FileRef{}}
			for format, relative := range legacy.Image {
				canonical := filepath.Join(legacy.Key(), filename(format))
				if filename(format) == "" || relative != canonical {
					return nil, problem("integrity", "legacy image path is not canonical")
				}
				path, info, e := safeRegular(p.Path, filepath.Join("v1", canonical))
				if e != nil {
					return nil, e
				}
				var existing string
				e = tx.QueryRowContext(ctx, "SELECT id FROM files WHERE path=?", path).Scan(&existing)
				if e == nil {
					ref, _, e := fileRef(ctx, tx, existing)
					if e != nil {
						return nil, e
					}
					im.Files[format] = ref
					continue
				}
				if !errors.Is(e, sql.ErrNoRows) {
					return nil, e
				}
				f, e := os.Open(path)
				if e != nil {
					return nil, e
				}
				h := sha256.New()
				n, e := io.Copy(h, f)
				f.Close()
				if e != nil {
					return nil, e
				}
				ref := FileRef{ID: id(), SHA256: hex.EncodeToString(h.Sum(nil)), Size: n, Format: format, Modified: info.ModTime().UTC()}
				_, e = tx.ExecContext(ctx, "INSERT INTO files(id,path,sha256,size,format,modified,state) VALUES(?,?,?,?,?,?,?)", ref.ID, path, ref.SHA256, n, format, timestamp(ref.Modified), "ready")
				if e != nil {
					return nil, e
				}
				im.Files[format] = ref
			}
			c.Images = append(c.Images, im)
		}
		sortCatalog(&c)
		if e = validateCatalog(c); e != nil {
			return nil, e
		}
		if e = validateLegacyAliases(p.Path, c); e != nil {
			return nil, e
		}
		if e = s.verifyCatalog(ctx, tx, c); e != nil {
			return nil, e
		}
		v, e := s.saveCatalog(ctx, tx, q.Repository, "", c)
		if e != nil {
			return nil, e
		}
		_, e = tx.ExecContext(ctx, "INSERT INTO repositories(id,generation) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET generation=excluded.generation", q.Repository, v.Generation)
		return v, e
	case "export":
		v, e := s.catalog(ctx, tx, q.Repository, "")
		if e != nil {
			return nil, e
		}
		seconds := p.LeaseSeconds
		if seconds == 0 {
			seconds = int64(s.options.ExportLease / time.Second)
		}
		if seconds <= 0 || seconds > int64(s.options.ExportLease/time.Second) {
			return nil, problem("invalid", "export lease outside configured bounds")
		}
		leaseID := id()
		expires := s.now().Add(time.Duration(seconds) * time.Second)
		if _, e = tx.ExecContext(ctx, "INSERT INTO transfers(id,repository,generation,expires) VALUES(?,?,?,?)", leaseID, q.Repository, v.Generation, expires.Unix()); e != nil {
			return nil, e
		}
		if e = os.Mkdir(p.Path, 0700); e != nil {
			return nil, e
		}
		if e = os.Mkdir(filepath.Join(p.Path, "files"), 0700); e != nil {
			return nil, e
		}
		manifest := GenerationManifest{Schema: 1, Repository: q.Repository, Generation: v.Generation, Catalog: v.Catalog, Paths: map[string]string{}, Files: map[string]FileRef{}}
		for _, image := range v.Catalog.Images {
			for format, ref := range image.Files {
				manifest.Paths[image.Key()+"/"+filename(format)] = ref.ID
				if _, ok := manifest.Files[ref.ID]; ok {
					continue
				}
				actual, path, e := fileRef(ctx, tx, ref.ID)
				if e != nil {
					return nil, e
				}
				if actual != ref {
					return nil, problem("integrity", "export file metadata mismatch")
				}
				if e = copyVerified(path, filepath.Join(p.Path, "files", ref.ID), ref); e != nil {
					return nil, e
				}
				manifest.Files[ref.ID] = ref
			}
		}
		digest := sha256.Sum256(encode(V1Index(v.Catalog)))
		manifest.IndexSHA256 = hex.EncodeToString(digest[:])
		if e = writeDurable(filepath.Join(p.Path, "manifest.json"), encode(manifest)); e != nil {
			return nil, e
		}
		if e = syncDir(filepath.Join(p.Path, "files")); e != nil {
			return nil, e
		}
		if e = syncDir(p.Path); e != nil {
			return nil, e
		}
		if e = syncDir(filepath.Dir(p.Path)); e != nil {
			return nil, e
		}
		return map[string]any{"manifest": manifest, "transfer_id": leaseID, "expires": expires}, nil
	case "import-generation":
		if e := checkSelection(ctx, tx, q.Repository, p.Generation); e != nil {
			return nil, e
		}
		manifestPath, _, e := safeRegular(p.Path, "manifest.json")
		if e != nil {
			return nil, e
		}
		data, e := os.ReadFile(manifestPath)
		if e != nil {
			return nil, e
		}
		var m GenerationManifest
		if e = json.Unmarshal(data, &m); e != nil {
			return nil, e
		}
		if m.Schema != 1 || m.Repository != q.Repository || !component.MatchString(m.Generation) {
			return nil, problem("integrity", "manifest identity mismatch")
		}
		digest := sha256.Sum256(encode(V1Index(m.Catalog)))
		if hex.EncodeToString(digest[:]) != m.IndexSHA256 {
			return nil, problem("integrity", "manifest index checksum mismatch")
		}
		paths := map[string]string{}
		used := map[string]bool{}
		for _, im := range m.Catalog.Images {
			for fmt, ref := range im.Files {
				paths[im.Key()+"/"+filename(fmt)] = ref.ID
				declared, ok := m.Files[ref.ID]
				if !ok || declared != ref || !component.MatchString(ref.ID) {
					return nil, problem("integrity", "incomplete manifest files")
				}
				used[ref.ID] = true
			}
		}
		if string(encode(paths)) != string(encode(m.Paths)) || len(used) != len(m.Files) {
			return nil, problem("integrity", "manifest canonical paths differ")
		}
		for file, ref := range m.Files {
			source, _, e := safeRegular(p.Path, filepath.Join("files", file))
			if e != nil {
				return nil, e
			}
			var count int
			if e = tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM files WHERE id=?", file).Scan(&count); e != nil {
				return nil, e
			}
			if count > 0 {
				existing, _, e := fileRef(ctx, tx, file)
				if e != nil || existing != ref {
					return nil, problem("conflict", "stable file ID collision")
				}
				if e = checkFile(source, ref); e != nil {
					return nil, e
				}
				continue
			}
			f, e := os.Open(source)
			if e != nil {
				return nil, e
			}
			actual, e := s.commitFileID(ctx, tx, f, ref.Format, ref.SHA256, ref.Size, file, ref.Modified)
			f.Close()
			if e != nil {
				return nil, e
			}
			if actual != ref {
				return nil, problem("integrity", "import metadata differs")
			}
		}
		if e = s.verifyCatalog(ctx, tx, m.Catalog); e != nil {
			return nil, e
		}
		var previous []byte
		e = tx.QueryRowContext(ctx, "SELECT document FROM catalogs WHERE id=?", m.Generation).Scan(&previous)
		var v CatalogView
		if e == nil {
			if string(previous) != string(encode(m.Catalog)) {
				return nil, problem("conflict", "stable generation ID collision")
			}
			v, e = loadCatalog(ctx, tx, m.Generation)
		} else if errors.Is(e, sql.ErrNoRows) {
			v, e = s.saveCatalog(ctx, tx, q.Repository, m.Generation, m.Catalog)
		}
		if e != nil {
			return nil, e
		}
		_, e = tx.ExecContext(ctx, "INSERT INTO repositories(id,generation) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET generation=excluded.generation", q.Repository, v.Generation)
		return v, e
	}
	return nil, problem("invalid", "unknown transfer operation")
}
func validateLegacyAliases(root string, c Catalog) error {
	links := map[string]string{"v1/default": c.Vendors["default"]}
	for vendor, variant := range c.Vendors {
		if vendor != "default" {
			links["v1/"+vendor+"/default"] = variant
		}
	}
	for _, im := range c.Images {
		for _, tag := range im.Tags {
			if tag != im.Version {
				links[filepath.Join("v1", im.Vendor, im.Variant, im.Arch, im.Distribution, tag)] = im.Version
			}
		}
	}
	for relative, target := range links {
		actual, e := os.Readlink(filepath.Join(root, relative))
		if e != nil || actual != target {
			return problem("integrity", "legacy alias does not match index")
		}
	}
	return nil
}
func writeDurable(path string, b []byte) error {
	f, e := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if e != nil {
		return e
	}
	_, e = f.Write(b)
	if e == nil {
		e = f.Sync()
	}
	ce := f.Close()
	if e == nil {
		e = ce
	}
	return e
}
func checkFile(path string, ref FileRef) error {
	f, e := os.Open(path)
	if e != nil {
		return e
	}
	defer f.Close()
	h := sha256.New()
	n, e := io.Copy(h, f)
	if e != nil {
		return e
	}
	if n != ref.Size || hex.EncodeToString(h.Sum(nil)) != ref.SHA256 {
		return problem("integrity", "file checksum mismatch")
	}
	return nil
}
func copyVerified(source, dest string, ref FileRef) error {
	f, e := os.Open(source)
	if e != nil {
		return e
	}
	defer f.Close()
	out, e := os.OpenFile(dest, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if e != nil {
		return e
	}
	h := sha256.New()
	n, e := io.Copy(io.MultiWriter(out, h), f)
	if e == nil && (n != ref.Size || hex.EncodeToString(h.Sum(nil)) != ref.SHA256) {
		e = problem("integrity", "export file checksum mismatch")
	}
	if e == nil {
		e = out.Sync()
	}
	ce := out.Close()
	if e == nil {
		e = ce
	}
	return e
}
