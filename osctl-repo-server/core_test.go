package reposerver

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func testStore(t *testing.T) (*Store, *time.Time) {
	t.Helper()
	now := time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)
	s, e := OpenStore(Options{Root: t.TempDir(), MaxBytes: 1 << 24, MaxUploadBytes: 1 << 20, MaxRuns: 100, MaxLease: time.Hour, ExportLease: time.Minute, Now: func() time.Time { return now }})
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { s.Close() })
	return s, &now
}
func call(t *testing.T, s *Store, role, op, key string, p any, body string) Response {
	t.Helper()
	r := s.Execute(context.Background(), role, Request{RequestID: id(), Operation: op, Repository: "test", RunKey: key, Params: encode(p)}, strings.NewReader(body))
	if !r.OK {
		t.Fatalf("%s: %+v", op, r.Error)
	}
	return r
}
func begin(t *testing.T, s *Store, name string, items ...string) RunSummary {
	t.Helper()
	expected := []WorkItem{}
	for i, name := range items {
		expected = append(expected, WorkItem{ID: name, Order: i, Tags: []string{"latest"}})
	}
	r := call(t, s, "producer", "begin", "", BeginParams{ID: name, Attempt: 1, Source: Source{SHA: strings.Repeat("1", 40), InputDigest: "inputs", Ref: "refs/heads/staging", Event: "push"}, Expected: expected, LeaseSeconds: 600, Defaults: map[string]string{"default": "vendor", "vendor": "minimal"}}, "")
	var out RunSummary
	if e := json.Unmarshal(r.Result, &out); e != nil {
		t.Fatal(e)
	}
	return out
}
func uploadItem(t *testing.T, s *Store, key, item, version, bytes string) {
	t.Helper()
	descriptor := Descriptor{Tuple: Tuple{Vendor: "vendor", Variant: "minimal", Arch: "x86_64", Distribution: "debian", Version: version}, Formats: []string{"tar"}, ConfigDigest: "config"}
	call(t, s, "producer", "bind", key, BindParams{ItemID: item, Attempt: 1, Descriptor: descriptor}, "")
	h := sha256.Sum256([]byte(bytes))
	call(t, s, "producer", "upload", key, UploadParams{ItemID: item, Attempt: 1, Format: "tar", SHA256: hex.EncodeToString(h[:]), Size: int64(len(bytes))}, bytes)
	call(t, s, "producer", "result", key, ResultParams{ItemID: item, Attempt: 1, ConfigDigest: "config", State: "verified", BuildOK: true, TestsOK: true}, "")
}
func publish(t *testing.T, s *Store, key string, items ...string) {
	t.Helper()
	v, e := s.Catalog(context.Background(), "test", "")
	if e != nil {
		t.Fatal(e)
	}
	call(t, s, "publisher", "publish", key, PublishParams{Generation: v.Generation, Items: items, Defaults: map[string]string{"default": "vendor", "vendor": "minimal"}}, "")
}
func readImage(t *testing.T, s *Store, key, version string) string {
	t.Helper()
	f, e := s.OpenFile(context.Background(), "test", key, "vendor/minimal/x86_64/debian/"+version+"/image-archive.tar")
	if e != nil {
		t.Fatal(e)
	}
	defer f.File.Close()
	b, e := io.ReadAll(f.File)
	if e != nil {
		t.Fatal(e)
	}
	return string(b)
}

func TestPinnedRunAndPartialPublication(t *testing.T) {
	s, _ := testStore(t)
	base := begin(t, s, "base", "base")
	uploadItem(t, s, base.Key, "base", "13", "old")
	call(t, s, "producer", "finish", base.Key, map[string]any{}, "")
	publish(t, s, base.Key, "base")
	pinned := begin(t, s, "pinned")
	call(t, s, "producer", "finish", pinned.Key, map[string]any{}, "")
	call(t, s, "producer", "seal", pinned.Key, map[string]any{}, "")
	run := begin(t, s, "mixed", "replacement", "bad")
	uploadItem(t, s, run.Key, "replacement", "13", "new")
	call(t, s, "producer", "result", run.Key, ResultParams{ItemID: "bad", State: "failed", Message: "capture failed"}, "")
	call(t, s, "producer", "finish", run.Key, map[string]any{}, "")
	r := s.Execute(context.Background(), "producer", Request{RequestID: id(), Operation: "seal", Repository: "test", RunKey: run.Key, Params: encode(map[string]any{})}, strings.NewReader(""))
	if r.OK || r.Error.Code != "not_ready" {
		t.Fatalf("failed run sealed: %+v", r)
	}
	publish(t, s, run.Key, "replacement")
	if got := readImage(t, s, "", "13"); got != "new" {
		t.Fatal(got)
	}
	if got := readImage(t, s, pinned.Key, "13"); got != "old" {
		t.Fatal(got)
	}
}
func TestRequestReplayIntegrityAndAuthority(t *testing.T) {
	s, _ := testStore(t)
	run := begin(t, s, "run", "item")
	d := Descriptor{Tuple: Tuple{Vendor: "vendor", Variant: "minimal", Arch: "x86_64", Distribution: "debian", Version: "13"}, Formats: []string{"tar"}, ConfigDigest: "config"}
	call(t, s, "producer", "bind", run.Key, BindParams{ItemID: "item", Attempt: 1, Descriptor: d}, "")
	sum := sha256.Sum256([]byte("image"))
	request := Request{RequestID: "stable", Operation: "upload", Repository: "test", RunKey: run.Key, Params: encode(UploadParams{ItemID: "item", Attempt: 1, Format: "tar", SHA256: hex.EncodeToString(sum[:]), Size: 5})}
	first := s.Execute(context.Background(), "producer", request, strings.NewReader("image"))
	retry := s.Execute(context.Background(), "producer", request, strings.NewReader("image"))
	if !first.OK || string(encode(first)) != string(encode(retry)) {
		t.Fatalf("retry differs: %+v %+v", first, retry)
	}
	bad := s.Execute(context.Background(), "producer", request, strings.NewReader("wrong"))
	if bad.OK || bad.Error.Code != "integrity" {
		t.Fatal(bad)
	}
	request.Params = encode(UploadParams{ItemID: "item", Attempt: 1, Format: "tar", SHA256: hex.EncodeToString(sum[:]), Size: 6})
	bad = s.Execute(context.Background(), "producer", request, strings.NewReader("image!"))
	if bad.OK || bad.Error.Code != "conflict" {
		t.Fatal(bad)
	}
	bad = s.Execute(context.Background(), "producer", Request{RequestID: id(), Operation: "publish", Repository: "test", RunKey: run.Key, Params: encode(PublishParams{})}, nil)
	if bad.OK || bad.Error.Code != "forbidden" {
		t.Fatal(bad)
	}
}
func TestPortableRoundTripAndIncompleteImport(t *testing.T) {
	s, _ := testStore(t)
	run := begin(t, s, "run", "item")
	uploadItem(t, s, run.Key, "item", "13", "durable bytes")
	publish(t, s, run.Key, "item")
	path := filepath.Join(t.TempDir(), "export")
	call(t, s, "admin", "export", "", TransferParams{Path: path, LeaseSeconds: 30}, "")
	dest, _ := testStore(t)
	r := call(t, dest, "admin", "import-generation", "", TransferParams{Path: path}, "")
	var imported CatalogView
	if e := json.Unmarshal(r.Result, &imported); e != nil {
		t.Fatal(e)
	}
	if got := readImage(t, dest, "", "13"); got != "durable bytes" {
		t.Fatal(got)
	}
	original, _ := s.Catalog(context.Background(), "test", "")
	if imported.Generation != original.Generation || string(encode(V1Index(imported.Catalog))) != string(encode(V1Index(original.Catalog))) {
		t.Fatal("generation/catalog identity changed")
	}
	for _, im := range imported.Catalog.Images {
		for _, ref := range im.Files {
			os.WriteFile(filepath.Join(path, "files", ref.ID), []byte("broken"), 0600)
		}
	}
	bad := s.Execute(context.Background(), "admin", Request{RequestID: id(), Operation: "import-generation", Repository: "test", Params: encode(TransferParams{Path: path, Generation: imported.Generation})}, nil)
	if bad.OK {
		t.Fatal("accepted corrupted import")
	}
	if got := readImage(t, dest, "", "13"); got != "durable bytes" {
		t.Fatal(got)
	}
}
func TestExpireReclaimAndOpenRead(t *testing.T) {
	s, now := testStore(t)
	run := begin(t, s, "run", "item")
	uploadItem(t, s, run.Key, "item", "13", "read survives")
	call(t, s, "producer", "finish", run.Key, map[string]any{}, "")
	call(t, s, "producer", "seal", run.Key, map[string]any{}, "")
	f, e := s.OpenFile(context.Background(), "test", run.Key, "vendor/minimal/x86_64/debian/13/image-archive.tar")
	if e != nil {
		t.Fatal(e)
	}
	defer f.File.Close()
	*now = now.Add(time.Hour)
	call(t, s, "admin", "expire", "", map[string]any{}, "")
	call(t, s, "admin", "reclaim", "", map[string]any{}, "")
	if _, e = s.Catalog(context.Background(), "test", run.Key); e == nil {
		t.Fatal("expired run readable")
	}
	b, e := io.ReadAll(f.File)
	if e != nil || string(b) != "read survives" {
		t.Fatalf("open read lost: %s %v", b, e)
	}
	var count int
	if e = s.db.QueryRow("SELECT COUNT(*) FROM files").Scan(&count); e != nil || count != 0 {
		t.Fatalf("files remain: %d %v", count, e)
	}
}

func TestSlowUploadDoesNotBlockReader(t *testing.T) {
	s, _ := testStore(t)
	base := begin(t, s, "base", "item")
	uploadItem(t, s, base.Key, "item", "13", "public")
	publish(t, s, base.Key, "item")
	run := begin(t, s, "slow", "item")
	d := Descriptor{Tuple: Tuple{Vendor: "vendor", Variant: "minimal", Arch: "x86_64", Distribution: "debian", Version: "14"}, Formats: []string{"tar"}, ConfigDigest: "frozen"}
	call(t, s, "producer", "bind", run.Key, BindParams{ItemID: "item", Attempt: 1, Descriptor: d}, "")
	sum := sha256.Sum256([]byte("later"))
	reader, writer := io.Pipe()
	done := make(chan Response, 1)
	go func() {
		done <- s.Execute(context.Background(), "producer", Request{RequestID: id(), Operation: "upload", Repository: "test", RunKey: run.Key, Params: encode(UploadParams{ItemID: "item", Attempt: 1, Format: "tar", SHA256: hex.EncodeToString(sum[:]), Size: 5})}, reader)
	}()
	readDone := make(chan string, 1)
	go func() {
		f, e := s.OpenFile(context.Background(), "test", "", "vendor/minimal/x86_64/debian/13/image-archive.tar")
		if e != nil {
			readDone <- e.Error()
			return
		}
		b, _ := io.ReadAll(f.File)
		f.File.Close()
		readDone <- string(b)
	}()
	select {
	case got := <-readDone:
		if got != "public" {
			t.Fatal(got)
		}
	case <-time.After(time.Second):
		writer.Close()
		t.Fatal("producer blocks public read")
	}
	writer.Write([]byte("later"))
	writer.Close()
	if r := <-done; !r.OK {
		t.Fatal(r.Error)
	}
}

func TestQuotaAndRestartRecovery(t *testing.T) {
	root := t.TempDir()
	now := time.Now().UTC()
	options := Options{Root: root, MaxBytes: 4, MaxUploadBytes: 4, MaxRuns: 1, MaxLease: time.Hour, ExportLease: time.Minute, Now: func() time.Time { return now }}
	s, e := OpenStore(options)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = OpenStore(options); e == nil {
		t.Fatal("second writer admitted")
	}
	run := begin(t, s, "one", "item")
	bad := s.Execute(context.Background(), "producer", Request{RequestID: id(), Operation: "begin", Repository: "test", Params: encode(BeginParams{ID: "two", Attempt: 1, Source: run.Source, LeaseSeconds: 600})}, nil)
	if bad.OK || bad.Error.Code != "quota" {
		t.Fatal(bad)
	}
	uploadItem(t, s, run.Key, "item", "13", "four")
	if e = s.Close(); e != nil {
		t.Fatal(e)
	}
	if e = os.WriteFile(filepath.Join(root, "pending", "interrupted"), []byte("partial"), 0600); e != nil {
		t.Fatal(e)
	}
	s, e = OpenStore(options)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	if _, e = os.Stat(filepath.Join(root, "pending", "interrupted")); !os.IsNotExist(e) {
		t.Fatalf("pending not reconciled: %v", e)
	}
	status := call(t, s, "producer", "status", run.Key, map[string]any{}, "")
	var got RunSummary
	json.Unmarshal(status.Result, &got)
	if got.Items[0].State != "verified" || got.Items[0].Files["tar"].SHA256 == "" {
		t.Fatal("receipt lost on restart")
	}
	if _, e = s.OpenFile(context.Background(), "test", run.Key, "vendor/minimal/x86_64/debian/13/image-archive.tar"); e == nil {
		t.Fatal("unsealed bytes exposed")
	}
}

func TestStaleGenerationAndAdmissionCannotRegress(t *testing.T) {
	s, _ := testStore(t)
	old := begin(t, s, "older", "item")
	newer := begin(t, s, "newer", "item")
	uploadItem(t, s, old.Key, "item", "13", "older")
	uploadItem(t, s, newer.Key, "item", "13", "newer")
	before, _ := s.Catalog(context.Background(), "test", "")
	publish(t, s, newer.Key, "item")
	oldParams := PublishParams{Generation: before.Generation, Items: []string{"item"}, Defaults: map[string]string{"default": "vendor", "vendor": "minimal"}}
	r := s.Execute(context.Background(), "publisher", Request{RequestID: id(), Operation: "publish", Repository: "test", RunKey: old.Key, Params: encode(oldParams)}, nil)
	if r.OK || r.Error.Code != "conflict" {
		t.Fatal(r)
	}
	current, _ := s.Catalog(context.Background(), "test", "")
	oldParams.Generation = current.Generation
	oldParams.Ancestors = []string{old.Source.SHA}
	r = s.Execute(context.Background(), "publisher", Request{RequestID: id(), Operation: "publish", Repository: "test", RunKey: old.Key, Params: encode(oldParams)}, nil)
	if r.OK || r.Error.Code != "superseded" {
		t.Fatal("equal-source ancestry bypassed admission")
	}
	call(t, s, "publisher", "publish", old.Key, PublishParams{Generation: current.Generation, Superseded: []string{"item"}}, "")
	after, _ := s.Catalog(context.Background(), "test", "")
	if after.Generation != current.Generation || readImage(t, s, "", "13") != "newer" {
		t.Fatal("stale publish changed state")
	}
}

func TestLegacyRecoveryMaterializationAndAdoption(t *testing.T) {
	s, _ := testStore(t)
	run := begin(t, s, "run", "item")
	uploadItem(t, s, run.Key, "item", "13", "static recovery bytes")
	publish(t, s, run.Key, "item")
	target := filepath.Join(t.TempDir(), "static")
	call(t, s, "admin", "export-legacy", "", TransferParams{Path: target}, "")
	other, _ := testStore(t)
	call(t, other, "admin", "import-legacy", "", TransferParams{Path: target}, "")
	if got := readImage(t, other, "", "latest"); got != "static recovery bytes" {
		t.Fatal(got)
	}
	before, _ := s.Catalog(context.Background(), "test", "")
	after, _ := other.Catalog(context.Background(), "test", "")
	if string(encode(V1Index(before.Catalog))) != string(encode(V1Index(after.Catalog))) {
		t.Fatal("static roundtrip differs")
	}
	outside := filepath.Join(t.TempDir(), "outside")
	os.WriteFile(outside, []byte("outside bytes"), 0600)
	payload := filepath.Join(target, "v1/vendor/minimal/x86_64/debian/13/image-archive.tar")
	os.Remove(payload)
	os.Symlink(outside, payload)
	badStore, _ := testStore(t)
	r := badStore.Execute(context.Background(), "admin", Request{RequestID: id(), Operation: "import-legacy", Repository: "test", Params: encode(TransferParams{Path: target})}, nil)
	if r.OK || r.Error.Code != "integrity" {
		t.Fatal("accepted symlink payload")
	}
}

func TestCorruptUploadHasNoCommittedReference(t *testing.T) {
	s, _ := testStore(t)
	run := begin(t, s, "run", "item")
	descriptor := Descriptor{Tuple: Tuple{Vendor: "vendor", Variant: "minimal", Arch: "x86_64", Distribution: "debian", Version: "13"}, Formats: []string{"tar"}, ConfigDigest: "capture"}
	call(t, s, "producer", "bind", run.Key, BindParams{ItemID: "item", Attempt: 1, Descriptor: descriptor}, "")
	sum := sha256.Sum256([]byte("complete"))
	r := s.Execute(context.Background(), "producer", Request{RequestID: id(), Operation: "upload", Repository: "test", RunKey: run.Key, Params: encode(UploadParams{ItemID: "item", Attempt: 1, Format: "tar", SHA256: hex.EncodeToString(sum[:]), Size: 8})}, strings.NewReader("partial"))
	if r.OK || r.Error.Code != "integrity" {
		t.Fatal(r)
	}
	var files, refs int
	s.db.QueryRow("SELECT COUNT(*) FROM files").Scan(&files)
	s.db.QueryRow("SELECT COUNT(*) FROM run_files").Scan(&refs)
	if files != 0 || refs != 0 {
		t.Fatalf("partial upload committed: files=%d refs=%d", files, refs)
	}
	entries, _ := os.ReadDir(filepath.Join(s.options.Root, "pending"))
	if len(entries) != 0 {
		t.Fatal("partial upload left pending bytes")
	}
}

func TestRestartReconcilesDurablePrecommitOrphan(t *testing.T) {
	root := t.TempDir()
	options := Options{Root: root, MaxBytes: 1 << 20, MaxUploadBytes: 1 << 16, MaxRuns: 10, MaxLease: time.Hour, ExportLease: time.Minute}
	s, e := OpenStore(options)
	if e != nil {
		t.Fatal(e)
	}
	run := begin(t, s, "baseline", "item")
	uploadItem(t, s, run.Key, "item", "13", "committed")
	publish(t, s, run.Key, "item")
	sum := sha256.Sum256([]byte("precommit"))
	prepared, e := s.prepareUpload(context.Background(), strings.NewReader("precommit"), UploadParams{Format: "tar", SHA256: hex.EncodeToString(sum[:]), Size: 9})
	if e != nil {
		t.Fatal(e)
	}
	orphanPath := prepared.path
	// This is the exact on-disk boundary after file+directory fsync and before
	// the database reference transaction. Reopen without its in-memory lease.
	if e = s.Close(); e != nil {
		t.Fatal(e)
	}
	s, e = OpenStore(options)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	if _, e = os.Stat(orphanPath); e != nil {
		t.Fatal("fixture did not preserve precommit orphan")
	}
	call(t, s, "admin", "reclaim", "", map[string]any{}, "")
	if _, e = os.Stat(orphanPath); !os.IsNotExist(e) {
		t.Fatalf("orphan remains: %v", e)
	}
	if got := readImage(t, s, "", "13"); got != "committed" {
		t.Fatal("recovery lost committed file")
	}
}

func TestRoleAndRepositoryMaintenanceBounds(t *testing.T) {
	s, now := testStore(t)
	run := begin(t, s, "one")
	for _, op := range []string{"export", "export-legacy", "import-generation", "import-legacy", "expire", "reclaim"} {
		r := s.Execute(context.Background(), "publisher", Request{RequestID: id(), Operation: op, Repository: "test", Params: encode(map[string]any{})}, nil)
		if r.OK || r.Error.Code != "forbidden" {
			t.Fatalf("publisher may perform %s: %+v", op, r)
		}
	}
	other := s.Execute(context.Background(), "producer", Request{RequestID: id(), Operation: "begin", Repository: "other", Params: encode(BeginParams{ID: "other", Attempt: 1, Source: run.Source, LeaseSeconds: 600})}, nil)
	if !other.OK {
		t.Fatal(other.Error)
	}
	var otherRun RunSummary
	json.Unmarshal(other.Result, &otherRun)
	*now = now.Add(time.Hour)
	call(t, s, "admin", "expire", "", map[string]any{}, "")
	var document []byte
	if e := s.db.QueryRow("SELECT document FROM runs WHERE key=?", otherRun.Key).Scan(&document); e != nil {
		t.Fatal(e)
	}
	json.Unmarshal(document, &otherRun)
	if otherRun.State == "expired" {
		t.Fatal("repository-scoped maintenance expired peer repository")
	}
}

func TestCatalogSelectionDoesNotReadBaselineBytes(t *testing.T) {
	for _, operation := range []string{"seal", "publish"} {
		t.Run(operation, func(t *testing.T) {
			s, _ := testStore(t)
			baseline := begin(t, s, "baseline", "old")
			uploadItem(t, s, baseline.Key, "old", "13", "verified baseline")
			publish(t, s, baseline.Key, "old")
			run := begin(t, s, "candidate", "new")
			uploadItem(t, s, run.Key, "new", "14", "verified candidate")
			call(t, s, "producer", "finish", run.Key, map[string]any{}, "")
			before, e := s.Catalog(context.Background(), "test", "")
			if e != nil {
				t.Fatal(e)
			}
			ref := before.Catalog.Images[0].Files["tar"]
			_, payload, e := fileRef(context.Background(), s.db, ref.ID)
			if e != nil {
				t.Fatal(e)
			}
			// A FIFO is a deterministic byte-I/O probe: opening/reading the
			// baseline would wait for this held writer. No production hook or
			// timing of a large cached file is needed to detect a rescan.
			saved := payload + ".verified"
			if e = os.Rename(payload, saved); e != nil {
				t.Fatal(e)
			}
			if e = syscall.Mkfifo(payload, 0600); e != nil {
				os.Rename(saved, payload)
				t.Fatal(e)
			}
			anchor, e := os.OpenFile(payload, os.O_RDWR, 0600)
			if e != nil {
				os.Remove(payload)
				os.Rename(saved, payload)
				t.Fatal(e)
			}
			released := false
			release := func() {
				if !released {
					released = true
					os.Remove(payload)
					os.Rename(saved, payload)
					anchor.Close()
				}
			}
			defer release()
			params := any(map[string]any{})
			role := "producer"
			if operation == "publish" {
				role = "publisher"
				params = PublishParams{Generation: before.Generation, Items: []string{"new"}, Defaults: before.Catalog.Vendors}
			}
			done := make(chan Response, 1)
			go func() {
				done <- s.Execute(context.Background(), role, Request{RequestID: id(), Operation: operation, Repository: "test", RunKey: run.Key, Params: encode(params)}, nil)
			}()
			var result Response
			select {
			case result = <-done:
			case <-time.After(2 * time.Second):
				// Restore the regular path before closing the FIFO: this also
				// releases an old implementation that has not opened it yet.
				release()
				result = <-done
				t.Error("catalog selection blocked on baseline byte I/O")
			}
			release()
			if !result.OK {
				t.Fatalf("%s rejected verified metadata: %+v", operation, result.Error)
			}
			key := ""
			if operation == "seal" {
				key = run.Key
			}
			if got := readImage(t, s, key, "14"); got != "verified candidate" {
				t.Fatal(got)
			}
			if got := readImage(t, s, key, "13"); got != "verified baseline" {
				t.Fatal(got)
			}
		})
	}
}

func TestCatalogSelectionRejectsChangedVerifiedReference(t *testing.T) {
	for _, operation := range []string{"seal", "publish"} {
		t.Run(operation, func(t *testing.T) {
			s, _ := testStore(t)
			base := begin(t, s, "base", "old")
			uploadItem(t, s, base.Key, "old", "13", "old")
			publish(t, s, base.Key, "old")
			run := begin(t, s, "candidate", "new")
			uploadItem(t, s, run.Key, "new", "14", "new")
			call(t, s, "producer", "finish", run.Key, map[string]any{}, "")
			before, _ := s.Catalog(context.Background(), "test", "")
			stored, e := loadRun(context.Background(), s.db, run.Key, "test")
			if e != nil {
				t.Fatal(e)
			}
			file := stored.Items[0].Files["tar"].ID
			if _, e = s.db.Exec("UPDATE files SET sha256=? WHERE id=?", strings.Repeat("0", 64), file); e != nil {
				t.Fatal(e)
			}
			role := "producer"
			p := any(map[string]any{})
			if operation == "publish" {
				role = "publisher"
				p = PublishParams{Generation: before.Generation, Items: []string{"new"}, Defaults: before.Catalog.Vendors}
			}
			result := s.Execute(context.Background(), role, Request{RequestID: id(), Operation: operation, Repository: "test", RunKey: run.Key, Params: encode(p)}, nil)
			if result.OK || result.Error.Code != "integrity" {
				t.Fatalf("accepted changed file identity: %+v", result)
			}
			after, _ := s.Catalog(context.Background(), "test", "")
			if after.Generation != before.Generation {
				t.Fatal("failed validation changed public catalog")
			}
		})
	}
}

func TestExportStillVerifiesPayloadBytes(t *testing.T) {
	s, _ := testStore(t)
	run := begin(t, s, "run", "item")
	uploadItem(t, s, run.Key, "item", "13", "good")
	publish(t, s, run.Key, "item")
	v, _ := s.Catalog(context.Background(), "test", "")
	ref := v.Catalog.Images[0].Files["tar"]
	_, path, e := fileRef(context.Background(), s.db, ref.ID)
	if e != nil {
		t.Fatal(e)
	}
	if e = os.WriteFile(path, []byte("bad!"), 0600); e != nil {
		t.Fatal(e)
	}
	for _, operation := range []string{"export", "export-legacy"} {
		result := s.Execute(context.Background(), "admin", Request{RequestID: id(), Operation: operation, Repository: "test", Params: encode(TransferParams{Path: filepath.Join(t.TempDir(), "export")})}, nil)
		if result.OK || result.Error.Code != "integrity" {
			t.Fatalf("%s accepted corrupt bytes: %+v", operation, result)
		}
	}
}

func TestConcurrentStalledUploadsReserveFilesystemHeadroom(t *testing.T) {
	s, _ := testStore(t)
	run := begin(t, s, "concurrent", "one", "two")
	for i, item := range []string{"one", "two"} {
		call(t, s, "producer", "bind", run.Key, BindParams{ItemID: item, Attempt: 1, Descriptor: Descriptor{Tuple: Tuple{Vendor: "vendor", Variant: "minimal", Arch: "x86_64", Distribution: "debian", Version: []string{"13", "14"}[i]}, Formats: []string{"tar"}, ConfigDigest: "capture"}}, "")
	}
	var stat syscall.Statfs_t
	if e := syscall.Statfs(s.options.Root, &stat); e != nil {
		t.Fatal(e)
	}
	available := stat.Bavail * uint64(stat.Bsize)
	size := int64(32 << 20)
	if available/16 < uint64(size) {
		size = int64(available / 16)
	}
	if size < 65536 {
		t.Fatal("fixture needs 1 MiB of temporary filesystem headroom")
	}
	// Only one byte is written. Configure enough *unreserved* free space for
	// one declared stream, but not two, without filling the real filesystem.
	s.options.MaxBytes = 3 * size
	s.options.MaxUploadBytes = size
	s.options.ReservedBytes = int64(available) - size - size/2
	request := func(item string) Request {
		return Request{RequestID: id(), Operation: "upload", Repository: "test", RunKey: run.Key, Params: encode(UploadParams{ItemID: item, Attempt: 1, Format: "tar", SHA256: strings.Repeat("0", 64), Size: size})}
	}
	firstReader, firstWriter := io.Pipe()
	firstDone := make(chan Response, 1)
	go func() { firstDone <- s.Execute(context.Background(), "producer", request("one"), firstReader) }()
	firstJoined := false
	defer func() {
		firstWriter.Close()
		if !firstJoined {
			<-firstDone
		}
	}()
	writeDone := make(chan error, 1)
	go func() { _, e := firstWriter.Write([]byte{1}); writeDone <- e }()
	select {
	case e := <-writeDone:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("first stream was not admitted")
	}
	s.mu.Lock()
	reserved := s.pendingBytes
	s.mu.Unlock()
	if reserved != size {
		t.Fatalf("first reservation=%d, want %d", reserved, size)
	}
	secondReader, secondWriter := io.Pipe()
	defer secondWriter.Close()
	secondDone := make(chan Response, 1)
	go func() { secondDone <- s.Execute(context.Background(), "producer", request("two"), secondReader) }()
	var result Response
	select {
	case result = <-secondDone:
	case <-time.After(2 * time.Second):
		secondWriter.Close()
		result = <-secondDone
		t.Error("second stalled stream was admitted against the first stream's reserved bytes")
	}
	if result.OK || result.Error.Code != "quota" {
		t.Fatalf("second stream should fail headroom admission: %+v", result)
	}
	firstWriter.Close()
	<-firstDone
	firstJoined = true
	s.mu.Lock()
	reserved = s.pendingBytes
	s.mu.Unlock()
	if reserved != 0 {
		t.Fatalf("failed stream retained reservation %d", reserved)
	}
}

func TestInitialSchemaFailureRollsBackAllDDL(t *testing.T) {
	root := t.TempDir()
	dbPath := filepath.Join(root, "catalog.sqlite")
	db, e := sql.Open("sqlite3", dbPath)
	if e != nil {
		t.Fatal(e)
	}
	// A late name collision makes the initial multi-statement creation fail
	// after its earlier CREATEs. None of those CREATEs/version may survive.
	if _, e = db.Exec("CREATE TABLE http_daily (sentinel INTEGER)"); e != nil {
		db.Close()
		t.Fatal(e)
	}
	db.Close()
	options := Options{Root: root, MaxBytes: 1 << 20, MaxUploadBytes: 1 << 16, MaxRuns: 10, MaxLease: time.Hour, ExportLease: time.Minute}
	if store, e := OpenStore(options); e == nil {
		store.Close()
		t.Fatal("accepted incompatible fresh fixture")
	}
	db, e = sql.Open("sqlite3", dbPath)
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	var version, created int
	if e = db.QueryRow("PRAGMA user_version").Scan(&version); e != nil {
		t.Fatal(e)
	}
	if e = db.QueryRow("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name!='http_daily'").Scan(&created); e != nil {
		t.Fatal(e)
	}
	if version != 0 || created != 0 {
		t.Fatalf("partial schema persisted: version=%d tables=%d", version, created)
	}
}
