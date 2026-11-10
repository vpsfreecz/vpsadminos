package reposerver

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

type Store struct {
	db           *sql.DB
	reads        *sql.DB
	cacheMu      sync.Mutex
	catalogs     map[string]*cachedCatalog
	cacheBytes   int
	mu           sync.Mutex
	options      Options
	lock         *os.File
	activeFiles  map[string]bool
	pendingBytes int64
}
type runRecord struct {
	RunSummary
	Baseline  string            `json:"baseline"`
	Admission int64             `json:"admission"`
	Defaults  map[string]string `json:"defaults,omitempty"`
}

const schema = `
CREATE TABLE files (id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, sha256 TEXT NOT NULL, size INTEGER NOT NULL, format TEXT NOT NULL, modified TEXT NOT NULL, state TEXT NOT NULL);
CREATE TABLE catalogs (id TEXT PRIMARY KEY, repository TEXT NOT NULL, document BLOB NOT NULL, modified TEXT NOT NULL, retain_until INTEGER NOT NULL);
CREATE TABLE refs (catalog TEXT NOT NULL REFERENCES catalogs(id) ON DELETE CASCADE, file TEXT NOT NULL REFERENCES files(id), PRIMARY KEY(catalog,file));
CREATE TABLE repositories (id TEXT PRIMARY KEY, generation TEXT NOT NULL REFERENCES catalogs(id));
CREATE TABLE runs (key TEXT PRIMARY KEY, repository TEXT NOT NULL, document BLOB NOT NULL);
CREATE TABLE run_files (run TEXT NOT NULL REFERENCES runs(key) ON DELETE CASCADE, file TEXT NOT NULL REFERENCES files(id), PRIMARY KEY(run,file));
CREATE TABLE requests (role TEXT NOT NULL, repository TEXT NOT NULL, id TEXT NOT NULL, digest TEXT NOT NULL, response BLOB NOT NULL, PRIMARY KEY(role,repository,id));
CREATE TABLE transfers (id TEXT PRIMARY KEY, repository TEXT NOT NULL, generation TEXT NOT NULL REFERENCES catalogs(id), expires INTEGER NOT NULL);
CREATE TABLE http_daily (repository TEXT NOT NULL, instance TEXT NOT NULL, day TEXT NOT NULL, dimensions TEXT NOT NULL, requests INTEGER NOT NULL, bytes INTEGER NOT NULL, PRIMARY KEY(repository,instance,day,dimensions));
PRAGMA user_version=1;`

func OpenStore(options Options) (*Store, error) {
	if options.Root == "" || options.MaxBytes <= 0 || options.ReservedBytes < 0 || options.MaxUploadBytes <= 0 || options.MaxRuns <= 0 || options.MaxLease <= 0 || options.ExportLease <= 0 {
		return nil, problem("invalid", "explicit positive storage/run/lease limits required")
	}
	if options.Now == nil {
		options.Now = time.Now
	}
	root, e := filepath.Abs(options.Root)
	if e != nil {
		return nil, e
	}
	options.Root = root
	for _, dir := range []string{root, filepath.Join(root, "files"), filepath.Join(root, "pending")} {
		if e = os.MkdirAll(dir, 0700); e != nil {
			return nil, e
		}
	}
	lock, e := os.OpenFile(filepath.Join(root, "writer.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if e != nil {
		return nil, e
	}
	if e = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); e != nil {
		lock.Close()
		return nil, problem("conflict", "another service owns storage")
	}
	// Inspect existing state read-only before enabling WAL or startup cleanup.
	databasePath := filepath.Join(root, "catalog.sqlite")
	if _, err := os.Stat(databasePath); err == nil {
		probe, err := sql.Open("sqlite3", "file:"+url.PathEscape(databasePath)+"?mode=ro")
		if err != nil {
			lock.Close()
			return nil, err
		}
		var version int
		err = probe.QueryRow("PRAGMA user_version").Scan(&version)
		probe.Close()
		if err != nil {
			lock.Close()
			return nil, err
		}
		if version > 3 || version < 0 {
			lock.Close()
			return nil, problem("invalid", "unsupported database schema")
		}
	} else if !os.IsNotExist(err) {
		lock.Close()
		return nil, err
	}
	dsn := "file:" + url.PathEscape(filepath.Join(root, "catalog.sqlite")) + "?_foreign_keys=on&_journal_mode=WAL&_synchronous=FULL&_busy_timeout=5000"
	db, e := sql.Open("sqlite3", dsn)
	if e != nil {
		lock.Close()
		return nil, e
	}
	db.SetMaxOpenConns(1)
	s := &Store{db: db, options: options, lock: lock, activeFiles: map[string]bool{}, catalogs: map[string]*cachedCatalog{}}
	var version int
	if e = db.QueryRow("PRAGMA user_version").Scan(&version); e == nil {
		if version < 0 || version > 3 {
			e = problem("invalid", "unsupported database schema")
		} else {
			if version == 0 {
				e = initializeSchema(db)
				version = 1
			}
			if e == nil && version == 1 {
				e = migrateSchema1(context.Background(), db)
				if e == nil {
					version = 2
				}
			}
			if e == nil && version == 2 {
				e = migrateSchema2(context.Background(), db)
			}
		}
	}
	if e != nil {
		s.Close()
		return nil, e
	}
	reads, err := sql.Open("sqlite3", "file:"+url.PathEscape(filepath.Join(root, "catalog.sqlite"))+"?mode=ro&_foreign_keys=on&_busy_timeout=5000&_query_only=on")
	if err != nil {
		s.Close()
		return nil, err
	}
	reads.SetMaxOpenConns(2)
	reads.SetMaxIdleConns(2)
	s.reads = reads
	if e = os.Chmod(filepath.Join(root, "catalog.sqlite"), 0600); e != nil {
		s.Close()
		return nil, e
	}
	// No uploader can be active while this process holds the exclusive owner lock
	// during startup. Unreferenced final files are recovered by explicit reclaim.
	entries, e := os.ReadDir(filepath.Join(root, "pending"))
	if e != nil {
		s.Close()
		return nil, e
	}
	for _, entry := range entries {
		if entry.IsDir() {
			s.Close()
			return nil, problem("integrity", "unexpected pending directory")
		}
		if e = os.Remove(filepath.Join(root, "pending", entry.Name())); e != nil {
			s.Close()
			return nil, e
		}
	}
	return s, nil
}

func initializeSchema(db *sql.DB) error {
	tx, e := db.Begin()
	if e != nil {
		return e
	}
	defer tx.Rollback()
	if _, e = tx.Exec(schema); e != nil {
		return e
	}
	return tx.Commit()
}
func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.reads != nil {
		_ = s.reads.Close()
	}
	e := s.db.Close()
	if s.lock != nil {
		s.lock.Close()
		s.lock = nil
	}
	return e
}
func (s *Store) now() time.Time { return s.options.Now().UTC() }
func id() string {
	b := make([]byte, 16)
	if _, e := rand.Read(b); e != nil {
		panic(e)
	}
	return hex.EncodeToString(b)
}
func encode(v any) []byte {
	b, e := json.Marshal(v)
	if e != nil {
		panic(e)
	}
	return b
}
func timestamp(t time.Time) string { return t.UTC().Format(time.RFC3339Nano) }

type querier interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

func loadRun(ctx context.Context, q querier, key, repo string) (runRecord, error) {
	var r runRecord
	var b []byte
	e := q.QueryRowContext(ctx, "SELECT document FROM runs WHERE key=? AND repository=?", key, repo).Scan(&b)
	if errors.Is(e, sql.ErrNoRows) {
		return r, problem("not_found", "run not found")
	}
	if e == nil {
		e = json.Unmarshal(b, &r)
	}
	return r, e
}
func loadCatalog(ctx context.Context, q querier, generation string) (CatalogView, error) {
	var v CatalogView
	var b []byte
	var modified string
	e := q.QueryRowContext(ctx, "SELECT repository,document,modified FROM catalogs WHERE id=?", generation).Scan(&v.Repository, &b, &modified)
	if errors.Is(e, sql.ErrNoRows) {
		return v, problem("not_found", "catalog not found")
	}
	if e != nil {
		return v, e
	}
	v.Generation = generation
	v.Scope = "public"
	e = json.Unmarshal(b, &v.Catalog)
	if e == nil {
		v.Modified, e = time.Parse(time.RFC3339Nano, modified)
	}
	return v, e
}
func saveRun(ctx context.Context, tx *sql.Tx, r runRecord) error {
	_, e := tx.ExecContext(ctx, "UPDATE runs SET document=? WHERE key=?", encode(r), r.Key)
	if e != nil {
		return e
	}
	_, e = tx.ExecContext(ctx, "DELETE FROM run_files WHERE run=?", r.Key)
	if e != nil {
		return e
	}
	ids := map[string]bool{}
	if r.State != "expired" {
		for _, item := range r.Items {
			for _, f := range item.Files {
				ids[f.ID] = true
			}
		}
	}
	for file := range ids {
		if _, e = tx.ExecContext(ctx, "INSERT INTO run_files(run,file) VALUES(?,?)", r.Key, file); e != nil {
			return e
		}
	}
	return nil
}
func (s *Store) saveCatalog(ctx context.Context, tx *sql.Tx, repo, generation string, c Catalog) (CatalogView, error) {
	if generation == "" {
		generation = id()
	}
	modified := s.now()
	_, e := tx.ExecContext(ctx, "INSERT INTO catalogs(id,repository,document,modified,retain_until) VALUES(?,?,?,?,?)", generation, repo, encode(c), timestamp(modified), modified.Add(s.options.ExportLease).Unix())
	if e != nil {
		return CatalogView{}, e
	}
	refs := map[string]bool{}
	for _, image := range c.Images {
		for _, f := range image.Files {
			refs[f.ID] = true
		}
	}
	for file := range refs {
		var state string
		if e = tx.QueryRowContext(ctx, "SELECT state FROM files WHERE id=?", file).Scan(&state); e != nil {
			return CatalogView{}, e
		}
		if state != "ready" {
			return CatalogView{}, problem("integrity", "file is not referenceable")
		}
		if _, e = tx.ExecContext(ctx, "INSERT INTO refs(catalog,file) VALUES(?,?)", generation, file); e != nil {
			return CatalogView{}, e
		}
	}
	return CatalogView{Repository: repo, Generation: generation, Scope: "public", Modified: modified, Catalog: c}, nil
}
func (s *Store) ensureRepo(ctx context.Context, tx *sql.Tx, repo string) (string, error) {
	var generation string
	e := tx.QueryRowContext(ctx, "SELECT generation FROM repositories WHERE id=?", repo).Scan(&generation)
	if e == nil {
		return generation, nil
	}
	if !errors.Is(e, sql.ErrNoRows) {
		return "", e
	}
	v, e := s.saveCatalog(ctx, tx, repo, "", emptyCatalog())
	if e != nil {
		return "", e
	}
	_, e = tx.ExecContext(ctx, "INSERT INTO repositories(id,generation) VALUES(?,?)", repo, v.Generation)
	return v.Generation, e
}
func (s *Store) catalog(ctx context.Context, q querier, repo, key string) (CatalogView, error) {
	if key != "" {
		r, e := loadRun(ctx, q, key, repo)
		if e != nil {
			return CatalogView{}, e
		}
		if r.State == "expired" || !r.Expires.After(s.now()) {
			return CatalogView{}, problem("expired", "run lease expired")
		}
		if r.State != "sealed" {
			return CatalogView{}, problem("not_ready", "run not sealed")
		}
		v, e := loadCatalog(ctx, q, r.Generation)
		v.Scope = "run"
		v.RunKey = key
		return v, e
	}
	var gen string
	e := q.QueryRowContext(ctx, "SELECT generation FROM repositories WHERE id=?", repo).Scan(&gen)
	if errors.Is(e, sql.ErrNoRows) {
		return CatalogView{}, problem("not_found", "repository not found")
	}
	if e != nil {
		return CatalogView{}, e
	}
	return loadCatalog(ctx, q, gen)
}
func (s *Store) Catalog(ctx context.Context, repo, key string) (CatalogView, error) {
	c, e := s.catalogSnapshot(ctx, repo, key)
	if e != nil {
		return CatalogView{}, e
	}
	return c.view, nil
}
func (s *Store) OpenFile(ctx context.Context, repo, key, path string) (*OpenedFile, error) {
	cached, e := s.catalogSnapshot(ctx, repo, key)
	if e != nil {
		return nil, e
	}
	v := cached.view
	im, format, e := cached.resolve(path)
	if e != nil {
		return nil, e
	}
	ref := im.Files[format]
	s.mu.Lock()
	defer s.mu.Unlock()
	// Recheck current visibility under admission before opening an inode.
	if err := s.catalogVisible(ctx, s.db, repo, key, v.Generation); err != nil {
		return nil, err
	}

	var stored, state string
	e = s.db.QueryRowContext(ctx, "SELECT path,state FROM files WHERE id=?", ref.ID).Scan(&stored, &state)
	if e != nil {
		return nil, e
	}
	if state != "ready" {
		return nil, problem("integrity", "referenced file unavailable")
	}
	f, e := os.Open(stored)
	if e != nil {
		return nil, problem("integrity", "referenced bytes missing")
	}
	info, e := f.Stat()
	if e != nil || !info.Mode().IsRegular() || info.Size() != ref.Size {
		f.Close()
		return nil, problem("integrity", "referenced file changed")
	}
	return &OpenedFile{File: f, Ref: ref, Tuple: im.Tuple, Path: path, View: v}, nil
}
func (s *Store) Storage(ctx context.Context, repo string) (StorageSummary, error) {
	tx, err := s.reads.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return StorageSummary{}, err
	}
	defer tx.Rollback()
	var v StorageSummary
	e := tx.QueryRowContext(ctx, "SELECT COALESCE(SUM(size),0),COUNT(*) FROM files").Scan(&v.Bytes, &v.Files)
	if e != nil {
		return v, e
	}
	rows, e := tx.QueryContext(ctx, "SELECT document FROM runs WHERE repository=? ORDER BY key", repo)
	if e != nil {
		return v, e
	}
	defer rows.Close()
	v.Runs = []RunSummary{}
	for rows.Next() {
		var b []byte
		var r runRecord
		if e = rows.Scan(&b); e != nil {
			return v, e
		}
		if e = json.Unmarshal(b, &r); e != nil {
			return v, e
		}
		v.Runs = append(v.Runs, r.RunSummary)
	}
	return v, rows.Err()
}

func (s *Store) commitFile(ctx context.Context, tx *sql.Tx, r io.Reader, format, checksum string, size int64) (FileRef, error) {
	if prepared, ok := r.(*preparedUpload); ok {
		ref := prepared.ref
		if ref.Format != format || ref.SHA256 != checksum || ref.Size != size {
			return FileRef{}, problem("integrity", "prepared upload differs")
		}
		_, e := tx.ExecContext(ctx, "INSERT INTO files(id,path,sha256,size,format,modified,state) VALUES(?,?,?,?,?,?,?)", ref.ID, prepared.path, ref.SHA256, ref.Size, ref.Format, timestamp(ref.Modified), "ready")
		return ref, e
	}
	return s.commitFileID(ctx, tx, r, format, checksum, size, id(), s.now())
}
func (s *Store) commitFileID(ctx context.Context, tx *sql.Tx, r io.Reader, format, checksum string, size int64, fileID string, modified time.Time) (FileRef, error) {
	var ref FileRef
	if filename(format) == "" || len(checksum) != 64 || size < 0 || size > s.options.MaxUploadBytes {
		return ref, problem("invalid", "invalid upload metadata")
	}
	if _, e := hex.DecodeString(checksum); e != nil {
		return ref, problem("invalid", "invalid checksum")
	}
	var used int64
	if e := tx.QueryRowContext(ctx, "SELECT COALESCE(SUM(size),0) FROM files").Scan(&used); e != nil {
		return ref, e
	}
	if size > s.options.MaxBytes-used-s.pendingBytes {
		return ref, problem("quota", "storage quota exceeded")
	}
	var stat syscall.Statfs_t
	if e := syscall.Statfs(s.options.Root, &stat); e != nil {
		return ref, e
	}
	if !hasUploadHeadroom(stat.Bavail*uint64(stat.Bsize), size, s.pendingBytes, s.options.ReservedBytes) {
		return ref, problem("quota", "reserved filesystem headroom")
	}
	ref = FileRef{ID: fileID, SHA256: strings.ToLower(checksum), Size: size, Format: format, Modified: modified}
	pending := filepath.Join(s.options.Root, "pending", ref.ID)
	final := filepath.Join(s.options.Root, "files", ref.ID)
	f, e := os.OpenFile(pending, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if e != nil {
		return FileRef{}, e
	}
	defer os.Remove(pending)
	hash := sha256.New()
	n, e := io.CopyN(io.MultiWriter(f, hash), r, size)
	if e == nil && (n != size || hex.EncodeToString(hash.Sum(nil)) != ref.SHA256) {
		e = problem("integrity", "upload checksum mismatch")
	}
	if e == nil {
		e = f.Sync()
	}
	closeErr := f.Close()
	if e == nil {
		e = closeErr
	}
	if e != nil {
		return FileRef{}, e
	}
	if e = os.Rename(pending, final); e != nil {
		return FileRef{}, e
	}
	if e = syncDir(filepath.Dir(final)); e != nil {
		return FileRef{}, e
	}
	_, e = tx.ExecContext(ctx, "INSERT INTO files(id,path,sha256,size,format,modified,state) VALUES(?,?,?,?,?,?,?)", ref.ID, final, ref.SHA256, ref.Size, format, timestamp(ref.Modified), "ready")
	return ref, e
}
func syncDir(path string) error {
	f, e := os.Open(path)
	if e != nil {
		return e
	}
	defer f.Close()
	return f.Sync()
}
func fileRef(ctx context.Context, q querier, file string) (FileRef, string, error) {
	var f FileRef
	var p, m, state string
	e := q.QueryRowContext(ctx, "SELECT id,path,sha256,size,format,modified,state FROM files WHERE id=?", file).Scan(&f.ID, &p, &f.SHA256, &f.Size, &f.Format, &m, &state)
	if e != nil {
		return f, "", e
	}
	if state != "ready" {
		return f, "", problem("integrity", "file unavailable")
	}
	f.Modified, e = time.Parse(time.RFC3339Nano, m)
	return f, p, e
}

type catalogFile struct {
	ref  FileRef
	path string
}

// catalogReferences validates the catalog against durable, already-verified
// immutable file records. Catalog selection must not rescan baseline payloads
// while holding the reader/reference mutex; bytes are checked at ingestion and
// when crossing an import/export boundary.
func (s *Store) catalogReferences(ctx context.Context, tx *sql.Tx, c Catalog) (map[string]catalogFile, error) {
	if e := validateCatalog(c); e != nil {
		return nil, e
	}
	files := map[string]catalogFile{}
	for _, im := range c.Images {
		for _, ref := range im.Files {
			if existing, ok := files[ref.ID]; ok {
				if existing.ref != ref {
					return nil, problem("integrity", "file manifest mismatch")
				}
				continue
			}
			actual, p, e := fileRef(ctx, tx, ref.ID)
			if e != nil {
				return nil, e
			}
			if actual != ref {
				return nil, problem("integrity", "file manifest mismatch")
			}
			files[ref.ID] = catalogFile{ref: ref, path: p}
		}
	}
	return files, nil
}

func (s *Store) verifyCatalog(ctx context.Context, tx *sql.Tx, c Catalog) error {
	files, e := s.catalogReferences(ctx, tx, c)
	if e != nil {
		return e
	}
	for _, entry := range files {
		f, e := os.Open(entry.path)
		if e != nil {
			return e
		}
		h := sha256.New()
		n, e := io.Copy(h, f)
		f.Close()
		if e != nil {
			return e
		}
		if n != entry.ref.Size || hex.EncodeToString(h.Sum(nil)) != entry.ref.SHA256 {
			return problem("integrity", "stored bytes changed")
		}
	}
	return nil
}
func orderedItems(r runRecord) []WorkItem {
	items := append([]WorkItem{}, r.Items...)
	sort.SliceStable(items, func(i, j int) bool { return items[i].Order < items[j].Order })
	return items
}
func findItem(r *runRecord, id string) (*WorkItem, error) {
	for i := range r.Items {
		if r.Items[i].ID == id {
			return &r.Items[i], nil
		}
	}
	return nil, problem("not_found", "work item not found")
}
func sourceValid(s Source) bool {
	return len(s.SHA) == 40 && len(s.InputDigest) > 0 && len(s.InputDigest) <= 256 && len(s.Ref) <= 256 && len(s.Event) <= 64
}
func requireRunOpen(r runRecord, now time.Time) error {
	if r.State == "expired" || !r.Expires.After(now) {
		return problem("expired", "run lease expired")
	}
	if r.State != "open" {
		return problem("conflict", "run no longer open")
	}
	return nil
}
func (s *Store) lease(seconds int64) (time.Time, error) {
	if seconds <= 0 || seconds > int64(s.options.MaxLease/time.Second) {
		return time.Time{}, problem("invalid", "lease outside configured bounds")
	}
	return s.now().Add(time.Duration(seconds) * time.Second), nil
}

// File inventory diagnostics intentionally exclude paths from public readers.
func (s *Store) String() string { return fmt.Sprintf("image store %s", s.options.Root) }
