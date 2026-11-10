package reposerver

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"time"
)

func (s *Store) RecordHTTP(ctx context.Context, e AccessEvent, days, maxRows int) error {
	return s.RecordHTTPBatch(ctx, []AccessEvent{e}, days, maxRows)
}

// One short writer transaction accounts for the accepted batch. Legacy keys,
// requests and bytes are retained exactly, including non-image categories.
func (s *Store) RecordHTTPBatch(ctx context.Context, events []AccessEvent, days, maxRows int) error {
	if days < 1 || maxRows < 1 {
		return fmt.Errorf("statistics need finite bounds")
	}
	if len(events) == 0 {
		return nil
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	type group struct{ repo, instance string }
	groups := map[group]time.Time{}
	usageChanged := map[group]bool{}
	for _, e := range events {
		g := group{e.Repository, e.Instance}
		if e.Timestamp.After(groups[g]) {
			groups[g] = e.Timestamp
		}
	}
	for g, now := range groups {
		cutoff := now.UTC().AddDate(0, 0, -days+1).Format("2006-01-02")
		deleted, deleteErr := tx.ExecContext(ctx, "DELETE FROM http_daily WHERE repository=? AND instance=? AND day<?", g.repo, g.instance, cutoff)
		if deleteErr != nil {
			return deleteErr
		}
		removed, deleteErr := deleted.RowsAffected()
		if deleteErr != nil {
			return deleteErr
		}
		usageChanged[g] = removed > 0
	}
	counts := map[group]int{}
	for g := range groups {
		var n int
		if err = tx.QueryRowContext(ctx, "SELECT count(*) FROM http_daily WHERE repository=? AND instance=?", g.repo, g.instance).Scan(&n); err != nil {
			return err
		}
		counts[g] = n
	}

	type key struct {
		g               group
		day, dimensions string
	}
	type increment struct {
		k               AggregateKey
		requests, bytes int64
	}
	increments := map[key]increment{}
	for _, e := range events {
		g := group{e.Repository, e.Instance}
		day := e.Timestamp.UTC().Format("2006-01-02")
		if day < groups[g].UTC().AddDate(0, 0, -days+1).Format("2006-01-02") {
			continue
		}
		if e.Scope == "public" && e.Kind == "artifact" {
			usageChanged[g] = true
		}
		dim := aggregateKey(e)
		encoded, err := json.Marshal(dim)
		if err != nil {
			return err
		}
		k := key{g, day, string(encoded)}
		value := increments[k]
		value.k = dim
		value.requests++
		value.bytes += e.Bytes
		increments[k] = value
	}
	for entry, value := range increments {
		g, k := entry.g, value.k
		var existing int
		if err = tx.QueryRowContext(ctx, "SELECT count(*) FROM http_daily WHERE repository=? AND instance=? AND day=? AND dimensions=?", g.repo, g.instance, entry.day, entry.dimensions).Scan(&existing); err != nil {
			return err
		}
		if existing == 0 {
			if counts[g] >= maxRows {
				return fmt.Errorf("statistics row limit reached")
			}
			counts[g]++
		}
		_, err = tx.ExecContext(ctx, `INSERT INTO http_daily(repository,instance,day,dimensions,requests,bytes,scope,kind,distribution,arch,vendor,variant,version,format,method,outcome,status) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(repository,instance,day,dimensions) DO UPDATE SET requests=requests+excluded.requests,bytes=bytes+excluded.bytes`, g.repo, g.instance, entry.day, entry.dimensions, value.requests, value.bytes, k.Scope, k.Kind, k.Tuple.Distribution, k.Tuple.Arch, k.Tuple.Vendor, k.Tuple.Variant, k.Tuple.Version, k.Format, k.Method, k.Outcome, k.Status)
		if err != nil {
			return err
		}
	}

	for g := range groups {
		revision := 0
		if usageChanged[g] {
			revision = 1
		}
		// Non-image HTTP accounting must not invalidate the usage page which
		// caused it. Retention policy/pruning and public image changes do.
		_, err = tx.ExecContext(ctx, `INSERT INTO http_measurement(repository,instance,retention_days,revision,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(repository,instance) DO UPDATE SET retention_days=excluded.retention_days,revision=revision+CASE WHEN retention_days!=excluded.retention_days OR excluded.revision!=0 THEN 1 ELSE 0 END,updated_at=excluded.updated_at`, g.repo, g.instance, days, revision, timestamp(s.now()))
		if err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *Store) HTTPStatistics(ctx context.Context, repository, instance string) ([]DailyStatistic, error) {
	rows, err := s.reads.QueryContext(ctx, "SELECT day,dimensions,requests,bytes FROM http_daily WHERE repository=? AND instance=? ORDER BY day DESC,dimensions", repository, instance)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	stats := []DailyStatistic{}
	for rows.Next() {
		var stat DailyStatistic
		var key string
		if err = rows.Scan(&stat.Day, &key, &stat.Requests, &stat.Bytes); err != nil {
			return nil, err
		}
		if err = json.Unmarshal([]byte(key), &stat.AggregateKey); err != nil {
			return nil, err
		}
		stats = append(stats, stat)
	}
	return stats, rows.Err()
}

// Keep response groups deterministic even when the SQL result is empty.
func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
