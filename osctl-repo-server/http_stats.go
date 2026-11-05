package reposerver

import "time"

// AggregateKey excludes requester details, requested paths, run IDs and headers.
type AggregateKey struct {
	Scope   string `json:"scope"`
	Kind    string `json:"kind"`
	Tuple   Tuple  `json:"tuple"`
	Format  string `json:"format"`
	Method  string `json:"method"`
	Status  int    `json:"status"`
	Outcome string `json:"outcome"`
}

type DailyStatistic struct {
	Day string `json:"day"`
	AggregateKey
	Requests int64 `json:"requests"`
	Bytes    int64 `json:"bytes"`
}

func aggregateKey(e AccessEvent) AggregateKey {
	key := AggregateKey{Scope: e.Scope, Kind: e.Kind, Format: e.Format, Method: e.Method, Status: e.Status, Outcome: e.Outcome}
	if e.Tuple != nil {
		key.Tuple = *e.Tuple
	}
	if key.Method != "GET" && key.Method != "HEAD" {
		key.Method = "OTHER"
	}
	return key
}

// Retention is applied to event days, and is also enforced when reading an idle
// instance's persisted statistics after restart.
func recentStatistics(stats []DailyStatistic, days int, now time.Time) []DailyStatistic {
	cutoff := now.UTC().AddDate(0, 0, -days+1).Format("2006-01-02")
	out := []DailyStatistic{}
	for _, stat := range stats {
		if stat.Day >= cutoff {
			out = append(out, stat)
		}
	}
	return out
}
