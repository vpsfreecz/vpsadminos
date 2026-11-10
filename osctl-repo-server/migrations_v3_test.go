package reposerver

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/mattn/go-sqlite3"
)

var predecessorTables = []struct{ name, columns string }{
	{"files", "id,path,sha256,size,format,modified,state"},
	{"catalogs", "id,repository,document,modified,retain_until"},
	{"refs", "catalog,file"}, {"repositories", "id,generation"},
	{"runs", "key,repository,document"}, {"run_files", "run,file"},
	{"requests", "role,repository,id,digest,response"},
	{"transfers", "id,repository,generation,expires"},
	{"http_daily", "repository,instance,day,dimensions,requests,bytes"},
}

func snapshotSchema2(t *testing.T, db *sql.DB) map[string]string {
	t.Helper()
	out := map[string]string{}
	for _, table := range predecessorTables {
		columns := table.columns
		if table.name == "http_daily" {
			columns += ",scope,kind,distribution,arch,vendor,variant,version,format,method,outcome,status"
		}
		out[table.name] = tableContent(t, db, table.name, columns)
	}
	out["http_measurement"] = tableContent(t, db, "http_measurement", "repository,instance,retention_days,revision,updated_at")
	return out
}

// Build an actual schema2 predecessor from the original schema1 initializer and
// its unchanged conversion. Keep the root and absolute payload references fixed.
func populatedSchema2(t *testing.T) (string, Options) {
	t.Helper()
	root := filepath.Join(t.TempDir(), "state")
	opts := legacyOptions(root)
	opts.Now = func() time.Time { return time.Date(2026, 11, 10, 12, 0, 0, 0, time.UTC) }
	s, err := OpenStore(opts)
	if err != nil {
		t.Fatal(err)
	}
	sealed := begin(t, s, "schema3-sealed", "public")
	uploadItem(t, s, sealed.Key, "public", "13", "preserved public payload")
	call(t, s, "producer", "finish", sealed.Key, map[string]any{}, "")
	call(t, s, "producer", "seal", sealed.Key, map[string]any{}, "")
	publish(t, s, sealed.Key, "public")
	active := begin(t, s, "schema3-active", "pending")
	uploadItem(t, s, active.Key, "pending", "14", "preserved active payload")
	event := AccessEvent{Repository: "test", Instance: "three", Timestamp: s.now(), Scope: "public", Kind: "artifact", Method: "GET", Status: 200, Outcome: "complete", Bytes: 24, Tuple: &Tuple{Vendor: "vendor", Variant: "minimal", Arch: "x86_64", Distribution: "debian", Version: "13"}}
	if err = s.RecordHTTPBatch(context.Background(), []AccessEvent{event, event}, 365, 100); err != nil {
		t.Fatal(err)
	}
	var busy, log, done int
	if err = s.db.QueryRow("PRAGMA wal_checkpoint(TRUNCATE)").Scan(&busy, &log, &done); err != nil || busy != 0 {
		t.Fatal(busy, err)
	}
	if err = s.Close(); err != nil {
		t.Fatal(err)
	}
	oldSource := filepath.Join(t.TempDir(), "source.sqlite")
	if err = os.Rename(filepath.Join(root, "catalog.sqlite"), oldSource); err != nil {
		t.Fatal(err)
	}
	for _, suffix := range []string{"-wal", "-shm"} {
		path := filepath.Join(root, "catalog.sqlite") + suffix
		if info, e := os.Stat(path); e == nil {
			if suffix == "-wal" && info.Size() != 0 {
				t.Fatal("uncheckpointed source")
			}
			if e = os.Remove(path); e != nil {
				t.Fatal(e)
			}
		} else if !os.IsNotExist(e) {
			t.Fatal(e)
		}
	}
	old := legacyDB(t, root)
	if _, err = old.Exec("ATTACH DATABASE ? AS source", oldSource); err != nil {
		t.Fatal(err)
	}
	for _, table := range predecessorTables {
		if _, err = old.Exec("INSERT INTO " + table.name + " SELECT " + table.columns + " FROM source." + table.name); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = old.Exec("DETACH DATABASE source"); err != nil {
		t.Fatal(err)
	}
	if err = migrateSchema1(context.Background(), old); err != nil {
		t.Fatal(err)
	}
	if err = old.Close(); err != nil {
		t.Fatal(err)
	}
	return root, opts
}

func copyStoppedFixture(t *testing.T, source, target string) map[string]string {
	t.Helper()
	state := map[string]string{}
	err := filepath.WalkDir(source, func(path string, entry fs.DirEntry, e error) error {
		if e != nil {
			return e
		}
		info, e := entry.Info()
		if e != nil {
			return e
		}
		rel, e := filepath.Rel(source, path)
		if e != nil {
			return e
		}
		dst := filepath.Join(target, rel)
		if entry.IsDir() {
			if e = os.MkdirAll(dst, info.Mode().Perm()); e != nil {
				return e
			}
			return os.Chmod(dst, info.Mode().Perm())
		}
		if !info.Mode().IsRegular() {
			t.Fatal("unexpected fixture file", path)
		}
		data, e := os.ReadFile(path)
		if e != nil {
			return e
		}
		if e = os.WriteFile(dst, data, info.Mode().Perm()); e != nil {
			return e
		}
		if e = os.Chmod(dst, info.Mode().Perm()); e != nil {
			return e
		}
		sum := sha256.Sum256(data)
		state[rel] = info.Mode().Perm().String() + ":" + hex.EncodeToString(sum[:])
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return state
}

func TestSchema3PopulatedUpgradeAndCoherentSchema2Restore(t *testing.T) {
	root, opts := populatedSchema2(t)
	db, err := sql.Open("sqlite3", filepath.Join(root, "catalog.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	before := snapshotSchema2(t, db)
	var version int
	if err = db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 2 {
		t.Fatal(version, err)
	}
	db.Close()
	backup := filepath.Join(t.TempDir(), "complete-stopped-backup")
	bytesAndModes := copyStoppedFixture(t, root, backup)
	s, err := OpenStore(opts)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 3 {
		t.Fatal(version, err)
	}
	if got := string(encode(snapshotSchema2(t, s.db))); got != string(encode(before)) {
		t.Fatal("schema2 rows changed")
	}
	if readImage(t, s, "", "13") != "preserved public payload" {
		t.Fatal("native payload changed")
	}
	var indexes int
	if err = s.db.QueryRow("SELECT count(*) FROM sqlite_master WHERE type='index' AND name='http_daily_usage_expr'").Scan(&indexes); err != nil || indexes != 1 {
		t.Fatal(indexes, err)
	}
	// Preserve postbackup writes in displaced3, but do not claim a schema2 backup
	// can recover those later observations.
	if err = s.RecordHTTP(context.Background(), AccessEvent{Repository: "test", Instance: "three", Timestamp: s.now(), Kind: "index", Method: "GET", Status: 200}, 365, 100); err != nil {
		t.Fatal(err)
	}
	if err = s.Close(); err != nil {
		t.Fatal(err)
	}
	displaced := root + "-schema3-displaced"
	if err = os.Rename(root, displaced); err != nil {
		t.Fatal(err)
	}
	if got := copyStoppedFixture(t, backup, root); string(encode(got)) != string(encode(bytesAndModes)) {
		t.Fatal("complete restore bytes/modes differ")
	}
	check, err := sql.Open("sqlite3", "file:"+filepath.Join(root, "catalog.sqlite")+"?mode=ro")
	if err != nil {
		t.Fatal(err)
	}
	defer check.Close()
	if err = check.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 2 {
		t.Fatal(version, err)
	}
	if got := string(encode(snapshotSchema2(t, check))); got != string(encode(before)) {
		t.Fatal("schema2 restore changed rows")
	}
	if _, err = os.Stat(filepath.Join(displaced, "catalog.sqlite")); err != nil {
		t.Fatal("lost postbackup schema3 state", err)
	}
}

func TestSchema3MigrationRollbackAndRepeat(t *testing.T) {
	root, opts := populatedSchema2(t)
	db, err := sql.Open("sqlite3", filepath.Join(root, "catalog.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	before := snapshotSchema2(t, db)
	conn, err := db.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	err = conn.Raw(func(driver any) error {
		driver.(*sqlite3.SQLiteConn).RegisterAuthorizer(func(op int, _, _, _ string) int {
			if op == sqlite3.SQLITE_DROP_INDEX {
				return sqlite3.SQLITE_DENY
			}
			return sqlite3.SQLITE_OK
		})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	conn.Close()
	if err = migrateSchema2(context.Background(), db); err == nil {
		t.Fatal("accepted injected DROP INDEX denial")
	}
	conn, err = db.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err = conn.Raw(func(driver any) error { driver.(*sqlite3.SQLiteConn).RegisterAuthorizer(nil); return nil }); err != nil {
		t.Fatal(err)
	}
	conn.Close()
	var version, indexes int
	if err = db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 2 {
		t.Fatal(version, err)
	}
	if err = db.QueryRow("SELECT count(*) FROM sqlite_master WHERE name='http_daily_usage_expr'").Scan(&indexes); err != nil || indexes != 0 {
		t.Fatal("partial CREATE survived", indexes, err)
	}
	if err = db.QueryRow("SELECT count(*) FROM sqlite_master WHERE name='http_daily_usage'").Scan(&indexes); err != nil || indexes != 1 {
		t.Fatal("old index lost", indexes, err)
	}
	if string(encode(snapshotSchema2(t, db))) != string(encode(before)) {
		t.Fatal("rollback changed predecessor")
	}
	db.Close()
	for i := 0; i < 2; i++ {
		s, e := OpenStore(opts)
		if e != nil {
			t.Fatal(e)
		}
		if string(encode(snapshotSchema2(t, s.db))) != string(encode(before)) {
			t.Fatal("reopen changed predecessor")
		}
		s.Close()
	}
}

func TestUsageExpressionsV1RemainFrozen(t *testing.T) {
	want := []string{
		`CASE WHEN method='GET' AND status=200 AND outcome='complete' THEN requests ELSE 0 END`,
		`CASE WHEN method='GET' AND status=206 THEN requests ELSE 0 END`,
		`CASE WHEN method='GET' AND status IN (200,206) THEN bytes ELSE 0 END`,
		`CASE WHEN outcome='interrupted' THEN requests ELSE 0 END`,
		`CASE WHEN status>=400 THEN requests ELSE 0 END`,
	}
	got := []string{usageFullDownloadsV1, usageRangeRequestsV1, usageTransferredBytesV1, usageInterruptedRequestsV1, usageErrorRequestsV1}
	for i, expression := range want {
		if got[i] != expression || !strings.Contains(usageSums, "coalesce(sum("+expression+"),0)") || !strings.Contains(usageIndexV3, expression) {
			t.Fatal("persisted v1 expression drift", i)
		}
	}
}

func TestActualSchema2BinaryRejectsSchema3BeforeMutation(t *testing.T) {
	binary := os.Getenv("SCHEMA2_REPO_SERVER_BINARY")
	if binary == "" {
		t.Skip("set retained actual schema2 binary")
	}
	root := t.TempDir()
	s, err := OpenStore(legacyOptions(root))
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	pending := filepath.Join(root, "pending", "keep-before-cleanup")
	if err = os.WriteFile(pending, []byte("unchanged"), 0600); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(filepath.Join(root, "catalog.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, binary, "serve", "--root", root, "--listen", "invalid-listen-address", "--repository", "test", "--instance", "three", "--max-bytes", "16777216", "--max-upload-bytes", "1048576", "--max-runs", "100", "--max-lease", "1h", "--export-lease", "1m")
	output, err := command.CombinedOutput()
	if err == nil || ctx.Err() != nil || !strings.Contains(string(output), "unsupported database schema") {
		t.Fatalf("old2 refusal: %s: %v", output, err)
	}
	after, err := os.ReadFile(filepath.Join(root, "catalog.sqlite"))
	if err != nil || sha256.Sum256(before) != sha256.Sum256(after) {
		t.Fatal("old2 changed schema3", err)
	}
	if got, err := os.ReadFile(pending); err != nil || string(got) != "unchanged" {
		t.Fatal("old2 reached cleanup", err)
	}
}
