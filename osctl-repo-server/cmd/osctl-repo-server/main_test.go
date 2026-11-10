package main

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	reposerver "github.com/vpsfreecz/vpsadminos/osctl-repo-server"
)

func TestPresentationText(t *testing.T) {
	for _, tc := range []struct {
		name  string
		value string
		limit int
		valid bool
	}{
		{"empty", "", 128, true},
		{"plain text including markup", "Images <stable> & tested", 128, true},
		{"Unicode name boundary", strings.Repeat("ž", 128), 128, true},
		{"Unicode name too long", strings.Repeat("ž", 129), 128, false},
		{"Unicode purpose boundary", strings.Repeat("界", 512), 512, true},
		{"Unicode purpose too long", strings.Repeat("界", 513), 512, false},
		{"invalid UTF-8", string([]byte{0xff}), 128, false},
		{"newline", "one\ntwo", 128, false},
		{"NUL", "one\x00two", 128, false},
		{"DEL", "one\x7ftwo", 128, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := validatePresentationText("display-name", tc.value, tc.limit)
			if (err == nil) != tc.valid {
				t.Fatalf("valid=%t, error=%v", tc.valid, err)
			}
		})
	}
}

func TestDocumentedCustomRepositoryImport(t *testing.T) {
	ctx := context.Background()
	store, err := reposerver.OpenStore(reposerver.Options{Root: filepath.Join(t.TempDir(), "state"),
		MaxBytes: 1 << 20, MaxUploadBytes: 1 << 20, MaxRuns: 2,
		MaxLease: time.Hour, ExportLease: time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	tree := t.TempDir()
	vendor := filepath.Join(tree, "v1", "myrepo")
	if err := os.MkdirAll(filepath.Join(vendor, "minimal"), 0700); err != nil {
		t.Fatal(err)
	}
	for link, target := range map[string]string{
		filepath.Join(tree, "v1", "default"): "myrepo", filepath.Join(vendor, "default"): "minimal",
	} {
		if err := os.Symlink(target, link); err != nil {
			t.Fatal(err)
		}
	}
	indexPath := filepath.Join(tree, "v1", "INDEX.json")
	if err := os.WriteFile(indexPath, []byte(`{"vendors":{"default":"myrepo","myrepo":"minimal"},"images":[]}`), 0600); err != nil {
		t.Fatal(err)
	}
	importTree := func(id string) {
		t.Helper()
		params, err := json.Marshal(reposerver.TransferParams{Path: tree, Generation: ""})
		if err != nil {
			t.Fatal(err)
		}
		reply := store.Execute(ctx, "admin", reposerver.Request{RequestID: id, Operation: "import-legacy", Repository: "myrepo", Params: params}, nil)
		if !reply.OK {
			t.Fatalf("import: %v", reply.Error)
		}
	}
	importTree("empty-1")
	view, err := store.Catalog(ctx, "myrepo", "")
	if err != nil || view.Repository != "myrepo" || len(view.Catalog.Images) != 0 || view.Generation == "" {
		t.Fatalf("empty custom catalog: %+v, %v", view, err)
	}
	imageDir := filepath.Join(vendor, "minimal", "x86_64", "arch", "rolling")
	if err := os.MkdirAll(imageDir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(imageDir, "image-archive.tar"), []byte("custom payload"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("rolling", filepath.Join(filepath.Dir(imageDir), "latest")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(indexPath, []byte(`{"vendors":{"default":"myrepo","myrepo":"minimal"},"images":[{"vendor":"myrepo","variant":"minimal","arch":"x86_64","distribution":"arch","version":"rolling","tags":["latest"],"image":{"tar":"myrepo/minimal/x86_64/arch/rolling/image-archive.tar"}}]}`), 0600); err != nil {
		t.Fatal(err)
	}
	importTree("adopt-1")
	file, err := store.OpenFile(ctx, "myrepo", "", "default/default/x86_64/arch/latest/image-archive.tar")
	if err != nil {
		t.Fatal(err)
	}
	defer file.File.Close()
	data, err := io.ReadAll(file.File)
	if err != nil || string(data) != "custom payload" {
		t.Fatalf("adopted alias bytes: %q, %v", data, err)
	}
}

func TestInvalidPresentationBeforeStoreOpen(t *testing.T) {
	originalArgs := os.Args
	t.Cleanup(func() { os.Args = originalArgs })
	for _, flagName := range []string{"display-name", "purpose"} {
		t.Run(flagName, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "must-not-be-created")
			os.Args = []string{"osctl-repo-server", "serve", "--root", root,
				"--listen", "127.0.0.1:8080", "--repository", "custom", "--instance", "test",
				"--" + flagName, "invalid\ntext"}
			err := run()
			if err == nil || !strings.Contains(err.Error(), "--"+flagName) {
				t.Fatalf("expected presentation validation error, got %v", err)
			}
			if _, err := os.Stat(root); !os.IsNotExist(err) {
				t.Fatalf("store root was touched: %v", err)
			}
		})
	}
}
