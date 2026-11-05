// Package reposerver owns immutable image files and public and run catalogs.
package reposerver

import (
	"context"
	"encoding/json"
	"os"
	"time"
)

type Tuple struct {
	Vendor       string `json:"vendor"`
	Variant      string `json:"variant"`
	Arch         string `json:"arch"`
	Distribution string `json:"distribution"`
	Version      string `json:"version"`
}

type FileRef struct {
	ID       string    `json:"id"`
	SHA256   string    `json:"sha256"`
	Size     int64     `json:"size"`
	Format   string    `json:"format"`
	Modified time.Time `json:"modified"`
}

type Image struct {
	Tuple
	Tags      []string           `json:"tags"`
	Files     map[string]FileRef `json:"files"`
	Source    string             `json:"source,omitempty"`
	Admission int64              `json:"admission,omitempty"`
}

type Catalog struct {
	Vendors         map[string]string `json:"vendors"`
	Images          []Image           `json:"images"`
	PolicySource    string            `json:"policy_source,omitempty"`
	PolicyAdmission int64             `json:"policy_admission,omitempty"`
}

type CatalogView struct {
	Repository string    `json:"repository"`
	Generation string    `json:"generation"`
	Scope      string    `json:"scope"`
	RunKey     string    `json:"run_key,omitempty"`
	Modified   time.Time `json:"modified"`
	Catalog    Catalog   `json:"catalog"`
}

// OpenedFile pins the open inode, independent of later logical pruning/unlink.
// The reader owns File and must close it. Public content can change; run content
// is immutable once sealed. Path is the requested canonical/alias path.
type OpenedFile struct {
	File  *os.File
	Ref   FileRef
	Tuple Tuple
	Path  string
	View  CatalogView
}

type RunSummary struct {
	Key        string     `json:"key"`
	Repository string     `json:"repository"`
	ID         string     `json:"id"`
	Attempt    int        `json:"attempt"`
	State      string     `json:"state"`
	Source     Source     `json:"source"`
	Expires    time.Time  `json:"expires"`
	Items      []WorkItem `json:"items"`
	Generation string     `json:"generation,omitempty"`
}

type StorageSummary struct {
	Bytes int64        `json:"bytes"`
	Files int64        `json:"files"`
	Runs  []RunSummary `json:"runs"`
}

type Reader interface {
	Catalog(context.Context, string, string) (CatalogView, error)
	OpenFile(context.Context, string, string, string) (*OpenedFile, error)
	Storage(context.Context, string) (StorageSummary, error)
}

type Source struct {
	SHA         string `json:"sha"`
	InputDigest string `json:"input_digest"`
	Ref         string `json:"ref"`
	Event       string `json:"event"`
}

type Descriptor struct {
	Tuple
	Formats      []string `json:"formats"`
	ConfigDigest string   `json:"config_digest"`
}

type WorkItem struct {
	ID         string             `json:"id"`
	Order      int                `json:"order"`
	Tags       []string           `json:"tags"`
	Attempt    int                `json:"attempt"`
	State      string             `json:"state"`
	Descriptor *Descriptor        `json:"descriptor,omitempty"`
	Files      map[string]FileRef `json:"files,omitempty"`
	Message    string             `json:"message,omitempty"`
}

type Request struct {
	RequestID  string          `json:"request_id"`
	Operation  string          `json:"operation"`
	Repository string          `json:"repository"`
	RunKey     string          `json:"run_key,omitempty"`
	Params     json.RawMessage `json:"params"`
}

type Response struct {
	OK     bool            `json:"ok"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  *Error          `json:"error,omitempty"`
}

type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string { return e.Code + ": " + e.Message }

type BeginParams struct {
	ID           string            `json:"id"`
	Attempt      int               `json:"attempt"`
	Source       Source            `json:"source"`
	Expected     []WorkItem        `json:"expected"`
	LeaseSeconds int64             `json:"lease_seconds"`
	Defaults     map[string]string `json:"defaults,omitempty"`
}

type BindParams struct {
	ItemID     string     `json:"item_id"`
	Attempt    int        `json:"attempt"`
	Descriptor Descriptor `json:"descriptor"`
}

// Upload bytes immediately follow the single JSON request line, exactly Size
// bytes. Upload is also a stable request: identical retries replay its response.
type UploadParams struct {
	ItemID  string `json:"item_id"`
	Attempt int    `json:"attempt"`
	Format  string `json:"format"`
	SHA256  string `json:"sha256"`
	Size    int64  `json:"size"`
}

type ResultParams struct {
	ItemID       string `json:"item_id"`
	Attempt      int    `json:"attempt"`
	State        string `json:"state"`
	BuildOK      bool   `json:"build_ok"`
	TestsOK      bool   `json:"tests_ok"`
	ConfigDigest string `json:"config_digest"`
	Message      string `json:"message,omitempty"`
}

type GCRule struct {
	Vendor       *string `json:"vendor"`
	Variant      *string `json:"variant"`
	Arch         *string `json:"arch"`
	Distribution *string `json:"distribution"`
	Version      *string `json:"version"`
	Keep         int     `json:"keep"`
}

type PublishParams struct {
	Generation string            `json:"generation"`
	Items      []string          `json:"items"`
	Defaults   map[string]string `json:"defaults"`
	GC         []GCRule          `json:"gc"`
	// Trusted publisher proves each older source is an ancestor of this run's
	// source. The service only accepts proofs matching current stored sources.
	Ancestors  []string `json:"ancestors"`
	Superseded []string `json:"superseded,omitempty"`
}

type Options struct {
	Root           string
	MaxBytes       int64
	ReservedBytes  int64
	MaxUploadBytes int64
	MaxRuns        int
	MaxLease       time.Duration
	ExportLease    time.Duration
	Now            func() time.Time
}
