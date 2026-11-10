package reposerver

import (
	"context"
	"time"
)

// DashboardReader is bound to one public repository and instance. It never
// exposes run identities, requester details or private filesystem paths.
type DashboardReader interface {
	DashboardOverview(context.Context) (DashboardOverview, error)
	DashboardCatalog(context.Context, CatalogQuery) (CatalogPage, error)
	DashboardUsage(context.Context, UsageQuery) (UsagePage, error)
}

type CatalogQuery struct {
	GroupBy, Distribution, Arch, Vendor, Variant, Cursor string
	Limit                                                int
}

type UsageQuery struct {
	Period, GroupBy, Distribution, Arch, Vendor, Variant, Version, Cursor string
	Limit                                                                 int
}

type DashboardMetadata struct {
	APIVersion  int       `json:"api_version"`
	Repository  string    `json:"repository"`
	Instance    string    `json:"instance"`
	GeneratedAt time.Time `json:"generated_at"`
}

type DashboardOverview struct {
	DashboardMetadata
	Generation    string            `json:"generation"`
	ImageVersions int64             `json:"image_versions"`
	StorageFiles  int64             `json:"storage_files"`
	StorageBytes  int64             `json:"storage_bytes"`
	RunStates     map[string]int64  `json:"run_states"`
	ItemStates    map[string]int64  `json:"item_states"`
	NextExpiry    *time.Time        `json:"next_expiry,omitempty"`
	Measurement   MeasurementHealth `json:"measurement"`
}

type DashboardDownload struct {
	Format string `json:"format"`
	URL    string `json:"url"`
	Bytes  int64  `json:"bytes"`
}

type CatalogRow struct {
	Tuple
	ImageVersions int64               `json:"image_versions"`
	Tags          []string            `json:"tags,omitempty"`
	Downloads     []DashboardDownload `json:"downloads,omitempty"`
}

type CatalogPage struct {
	DashboardMetadata
	Generation string       `json:"generation"`
	GroupBy    string       `json:"group_by"`
	Rows       []CatalogRow `json:"rows"`
	NextCursor string       `json:"next_cursor,omitempty"`
}

type UsageCounters struct {
	FullDownloads int64 `json:"full_downloads"`
	RangeRequests int64 `json:"range_requests"`
	// TransferredBytes counts accepted response-body writes for image GET
	// 200/206, including multipart framing and excluding HTTP headers.
	TransferredBytes    int64 `json:"transferred_bytes"`
	InterruptedRequests int64 `json:"interrupted_requests"`
	ErrorRequests       int64 `json:"error_requests"`
}

type UsageCoverage struct {
	RetainedFrom    *time.Time        `json:"retained_from"`
	RetentionDays   int               `json:"retention_days"`
	HistoryComplete bool              `json:"history_complete"`
	Measurement     MeasurementHealth `json:"measurement"`
}

type UsageRow struct {
	Tuple
	UsageCounters
}

type UsageDay struct {
	Day string `json:"day"`
	UsageCounters
}

type UsagePage struct {
	DashboardMetadata
	Period     string        `json:"period"`
	GroupBy    string        `json:"group_by"`
	Start      time.Time     `json:"start"`
	End        time.Time     `json:"end"`
	UpdatedAt  *time.Time    `json:"updated_at"`
	Coverage   UsageCoverage `json:"coverage"`
	Totals     UsageCounters `json:"totals"`
	Rows       []UsageRow    `json:"rows"`
	Days       []UsageDay    `json:"days"`
	NextCursor string        `json:"next_cursor,omitempty"`
}
