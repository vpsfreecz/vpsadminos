package reposerver

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func legacyOptions(root string) Options {
	return Options{Root: root, MaxBytes: 1 << 24, MaxUploadBytes: 1 << 20, MaxRuns: 100, MaxLease: time.Hour, ExportLease: time.Minute}
}
func legacyDB(t *testing.T, root string) *sql.DB {
	t.Helper()
	db, e := sql.Open("sqlite3", filepath.Join(root, "catalog.sqlite"))
	if e != nil {
		t.Fatal(e)
	}
	if e = initializeSchema(db); e != nil {
		t.Fatal(e)
	}
	return db
}
func TestSchema1MigrationPreservesStateAndCounters(t *testing.T) {
	s, _ := testStore(t)
	run := begin(t, s, "migrate", "image")
	uploadItem(t, s, run.Key, "image", "13", "immutable bytes")
	call(t, s, "producer", "finish", run.Key, map[string]any{}, "")
	call(t, s, "producer", "seal", run.Key, map[string]any{}, "")
	publish(t, s, run.Key, "image")
	active := begin(t, s, "active", "queued")
	_ = active
	e := AccessEvent{Repository: "test", Instance: "one", Timestamp: s.now(), Scope: "public", Kind: "artifact", Tuple: &Tuple{Vendor: "vendor", Variant: "minimal", Arch: "x86_64", Distribution: "debian", Version: "13"}, Method: "GET", Status: 200, Bytes: 15, Outcome: "complete"}
	if err := s.RecordHTTPBatch(context.Background(), []AccessEvent{e, e}, 365, 100); err != nil {
		t.Fatal(err)
	}
	// Construct actual schema-1 tables from its retained definition, copying every
	// original column; this does not relabel a schema-2 database as schema 1.
	root := t.TempDir()
	old := legacyDB(t, root)
	tables := []struct{ name, columns string }{{"files", "id,path,sha256,size,format,modified,state"}, {"catalogs", "id,repository,document,modified,retain_until"}, {"refs", "catalog,file"}, {"repositories", "id,generation"}, {"runs", "key,repository,document"}, {"run_files", "run,file"}, {"requests", "role,repository,id,digest,response"}, {"transfers", "id,repository,generation,expires"}, {"http_daily", "repository,instance,day,dimensions,requests,bytes"}}
	if _, err := old.Exec("ATTACH DATABASE ? AS source", filepath.Join(s.options.Root, "catalog.sqlite")); err != nil {
		t.Fatal(err)
	}
	before := map[string]string{}
	for _, table := range tables {
		if _, err := old.Exec("INSERT INTO " + table.name + " SELECT " + table.columns + " FROM source." + table.name); err != nil {
			t.Fatal(err)
		}
		before[table.name] = tableContent(t, old, table.name, table.columns)
	}
	old.Close()
	upgraded, err := OpenStore(legacyOptions(root))
	if err != nil {
		t.Fatal(err)
	}
	for _, table := range tables {
		if got := tableContent(t, upgraded.db, table.name, table.columns); got != before[table.name] {
			t.Fatalf("changed predecessor rows in %s: %s != %s", table.name, got, before[table.name])
		}
	}
	stats, err := upgraded.HTTPStatistics(context.Background(), "test", "one")
	if err != nil || len(stats) != 1 || stats[0].Requests != 2 || stats[0].Bytes != 30 {
		t.Fatal(stats, err)
	}
	if got := readImage(t, upgraded, "", "13"); got != "immutable bytes" {
		t.Fatal(got)
	}
	var version int
	upgraded.db.QueryRow("PRAGMA user_version").Scan(&version)
	if version != 2 {
		t.Fatal(version)
	}
	upgraded.Close()
	again, err := OpenStore(legacyOptions(root))
	if err != nil {
		t.Fatal(err)
	}
	again.Close()
}
func TestSchema1MalformedConversionRollsBack(t *testing.T) {
	root := t.TempDir()
	db := legacyDB(t, root)
	_, err := db.Exec(`INSERT INTO http_daily VALUES('test','one','2026-11-10','not JSON',3,17)`)
	if err != nil {
		t.Fatal(err)
	}
	if err = migrateSchema1(context.Background(), db); err == nil {
		t.Fatal("accepted malformed predecessor")
	}
	var v int
	db.QueryRow("PRAGMA user_version").Scan(&v)
	if v != 1 {
		t.Fatal(v)
	}
	rows, err := db.Query("SELECT dimensions,requests,bytes FROM http_daily")
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	if !rows.Next() {
		t.Fatal("lost predecessor")
	}
	var dim string
	var n, b int
	rows.Scan(&dim, &n, &b)
	if dim != "not JSON" || n != 3 || b != 17 {
		t.Fatal(dim, n, b)
	}
	rows.Close()
	var columns int
	db.QueryRow("SELECT count(*) FROM pragma_table_info('http_daily')").Scan(&columns)
	if columns != 6 {
		t.Fatalf("partial ALTER persisted: %d", columns)
	}
	db.Close()
}
func TestFutureSchemaRefusesBeforeCleanup(t *testing.T) {
	root := t.TempDir()
	db := legacyDB(t, root)
	db.Exec("PRAGMA user_version=99")
	db.Close()
	os.Mkdir(filepath.Join(root, "pending"), 0700)
	pending := filepath.Join(root, "pending", "keep")
	os.WriteFile(pending, []byte("retained"), 0600)
	if s, err := OpenStore(legacyOptions(root)); err == nil {
		s.Close()
		t.Fatal("accepted future schema")
	}
	if b, err := os.ReadFile(pending); err != nil || string(b) != "retained" {
		t.Fatal(string(b), err)
	}
}
func tableContent(t *testing.T, db *sql.DB, table, columns string) string {
	t.Helper()
	rows, e := db.Query("SELECT " + columns + " FROM " + table + " ORDER BY " + columns)
	if e != nil {
		t.Fatal(e)
	}
	defer rows.Close()
	names, _ := rows.Columns()
	out := []any{}
	for rows.Next() {
		values := make([]any, len(names))
		pointers := make([]any, len(names))
		for i := range values {
			pointers[i] = &values[i]
		}
		if e = rows.Scan(pointers...); e != nil {
			t.Fatal(e)
		}
		out = append(out, values)
	}
	if e = rows.Err(); e != nil {
		t.Fatal(e)
	}
	b, e := json.Marshal(out)
	if e != nil {
		t.Fatal(e)
	}
	return string(b)
}
func TestSchema1DefinitionRemainsLegacy(t *testing.T) {
	if !strings.Contains(schema, "PRAGMA user_version=1;") {
		t.Fatal("initial predecessor changed")
	}
}
func TestSchema1InjectedSQLFailureRollsBack(t *testing.T) {
	root := t.TempDir()
	db := legacyDB(t, root)
	defer db.Close()
	if _, e := db.Exec("CREATE TABLE http_measurement(blocker TEXT)"); e != nil {
		t.Fatal(e)
	}
	if e := migrateSchema1(context.Background(), db); e == nil {
		t.Fatal("accepted incompatible conversion")
	}
	var v int
	db.QueryRow("PRAGMA user_version").Scan(&v)
	if v != 1 {
		t.Fatal(v)
	}
	var n int
	db.QueryRow("SELECT count(*) FROM pragma_table_info('http_daily')").Scan(&n)
	if n != 6 {
		t.Fatal(fmt.Sprint(n))
	}
}

// Optional retained binary proof: invalid observer settings deliberately remain
// unset, so even a wrong binary cannot reach control/HTTP listener setup.
func TestLegacyBinaryRejectsSchema2(t *testing.T) {
	binary := os.Getenv("LEGACY_REPO_SERVER_BINARY")
	if binary == "" {
		t.Skip("set retained schema-1 binary for exact predecessor refusal proof")
	}
	root := t.TempDir()
	s, err := OpenStore(legacyOptions(root))
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, binary, "serve", "--root", root, "--listen", "invalid-listen-address", "--repository", "test", "--instance", "one", "--max-bytes", "16777216", "--max-upload-bytes", "1048576", "--max-runs", "100", "--max-lease", "1h", "--export-lease", "1m")
	output, err := command.CombinedOutput()
	if err == nil || !strings.Contains(string(output), "unsupported database schema") {
		t.Fatalf("legacy binary refusal: %s: %v", output, err)
	}
}
