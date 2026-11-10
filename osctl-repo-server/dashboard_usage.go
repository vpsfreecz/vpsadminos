package reposerver

import (
	"context"
	"database/sql"
	"fmt"
	"math"
	"strings"
	"time"
)

const usageSums = `coalesce(sum(CASE WHEN method='GET' AND status=200 AND outcome='complete' THEN requests ELSE 0 END),0),coalesce(sum(CASE WHEN method='GET' AND status=206 THEN requests ELSE 0 END),0),coalesce(sum(CASE WHEN method='GET' AND status IN (200,206) THEN bytes ELSE 0 END),0),coalesce(sum(CASE WHEN outcome='interrupted' THEN requests ELSE 0 END),0),coalesce(sum(CASE WHEN status>=400 THEN requests ELSE 0 END),0)`

func counterArgs(c *UsageCounters) []any {
	return []any{&c.FullDownloads, &c.RangeRequests, &c.TransferredBytes, &c.InterruptedRequests, &c.ErrorRequests}
}

func addUsageCounters(total *UsageCounters, day UsageCounters) error {
	for _, counter := range []struct {
		total *int64
		value int64
	}{
		{&total.FullDownloads, day.FullDownloads},
		{&total.RangeRequests, day.RangeRequests},
		{&total.TransferredBytes, day.TransferredBytes},
		{&total.InterruptedRequests, day.InterruptedRequests},
		{&total.ErrorRequests, day.ErrorRequests},
	} {
		// Match SQLite's integer SUM error instead of wrapping persisted values,
		// including negative counters from invalid historical content.
		if counter.value > 0 && *counter.total > math.MaxInt64-counter.value || counter.value < 0 && *counter.total < math.MinInt64-counter.value {
			return fmt.Errorf("integer overflow")
		}
		*counter.total += counter.value
	}
	return nil
}

func (d *StoreDashboardReader) DashboardUsage(ctx context.Context, q UsageQuery) (UsagePage, error) {
	if q.Period == "" {
		q.Period = "7d"
	}
	if q.GroupBy == "" {
		q.GroupBy = "distribution"
	}
	periods := map[string]int{"today": 1, "7d": 7, "30d": 30, "90d": 90, "180d": 180, "365d": 365}
	_, ok := periods[q.Period]
	if !ok {
		return UsagePage{}, problem("invalid", "unknown period")
	}
	if !contains([]string{"distribution", "arch", "image"}, q.GroupBy) {
		return UsagePage{}, problem("invalid", "unknown usage grouping")
	}
	limit, err := pageLimit(q.Limit)
	if err != nil {
		return UsagePage{}, err
	}
	if err = validFilters(q.Distribution, q.Arch, q.Vendor, q.Variant, q.Version); err != nil {
		return UsagePage{}, err
	}
	q.Limit = limit
	return d.cachedUsage(ctx, q)
}

func (d *StoreDashboardReader) materializeUsage(ctx context.Context, q UsageQuery, now time.Time) (UsagePage, int, error) {
	days := map[string]int{"today": 1, "7d": 7, "30d": 30, "90d": 90, "180d": 180, "365d": 365}[q.Period]
	tx, err := d.store.reads.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return UsagePage{}, 0, err
	}
	defer tx.Rollback()
	retention := 365
	var revision int64
	var updated string
	err = tx.QueryRowContext(ctx, "SELECT retention_days,revision,updated_at FROM http_measurement WHERE repository=? AND instance=?", d.repository, d.instance).Scan(&retention, &revision, &updated)
	if err != nil && err != sql.ErrNoRows {
		return UsagePage{}, 0, err
	}
	if d.observer != nil {
		retention = d.observer.opts.StatsDays
	}
	start := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC).AddDate(0, 0, -days+1)
	v := UsagePage{DashboardMetadata: d.metadata(), Period: q.Period, GroupBy: q.GroupBy, Start: start, End: now, Coverage: UsageCoverage{RetentionDays: retention, Measurement: d.health()}, Rows: []UsageRow{}, Days: []UsageDay{}}
	if updated != "" {
		t, e := time.Parse(time.RFC3339Nano, updated)
		if e != nil {
			return v, 0, e
		}
		v.UpdatedAt = &t
	}
	var earliest sql.NullString
	if err = tx.QueryRowContext(ctx, "SELECT min(day) FROM http_daily WHERE repository=? AND instance=?", d.repository, d.instance).Scan(&earliest); err != nil {
		return v, 0, err
	}
	if earliest.Valid {
		t, e := time.Parse("2006-01-02", earliest.String)
		if e != nil {
			return v, 0, e
		}
		v.Coverage.RetainedFrom = &t
	}
	cutoff := now.AddDate(0, 0, -retention+1).Format("2006-01-02")
	where := `repository=? AND instance=? AND scope='public' AND kind='artifact' AND day>=? AND day<=? AND day>=?`
	args := []any{d.repository, d.instance, start.Format("2006-01-02"), now.Format("2006-01-02"), cutoff}
	for _, f := range []struct{ name, value string }{{"distribution", q.Distribution}, {"arch", q.Arch}, {"vendor", q.Vendor}, {"variant", q.Variant}, {"version", q.Version}} {
		if f.value != "" {
			where += " AND " + f.name + "=?"
			args = append(args, f.value)
		}
	}
	rows, err := tx.QueryContext(ctx, "SELECT day,"+usageSums+" FROM http_daily WHERE "+where+" GROUP BY day ORDER BY day", args...)
	if err != nil {
		return v, 0, err
	}
	observed := map[string]UsageCounters{}
	for rows.Next() {
		var day string
		var counters UsageCounters
		a := append([]any{&day}, counterArgs(&counters)...)
		if err = rows.Scan(a...); err != nil {
			rows.Close()
			return v, 0, err
		}
		observed[day] = counters
		// Daily rows cover the full filter, independently of the page limit.
		// Reuse them rather than scanning the same measurements for totals.
		if err = addUsageCounters(&v.Totals, counters); err != nil {
			rows.Close()
			return v, 0, err
		}
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return v, 0, err
	}
	for date := start; !date.After(now); date = date.AddDate(0, 0, 1) {
		day := date.Format("2006-01-02")
		v.Days = append(v.Days, UsageDay{Day: day, UsageCounters: observed[day]})
	}
	dimensions := []string{"distribution"}
	if q.GroupBy == "arch" {
		dimensions = append(dimensions, "arch")
	}
	if q.GroupBy == "image" {
		dimensions = []string{"distribution", "arch", "vendor", "variant", "version"}
	}
	fields := strings.Join(dimensions, ",")
	query := "SELECT " + fields + "," + usageSums + " FROM http_daily WHERE " + where + " GROUP BY " + fields + " ORDER BY " + fmt.Sprint(len(dimensions)+1) + " DESC," + fields
	rows, err = tx.QueryContext(ctx, query, args...)
	if err != nil {
		return v, 0, err
	}
	// Account for slice capacity, counters, strings and per-result metadata.
	memory := 2048 + len(v.Days)*128
	for rows.Next() {
		var row UsageRow
		dest := []any{&row.Distribution}
		if q.GroupBy == "arch" {
			dest = append(dest, &row.Arch)
		}
		if q.GroupBy == "image" {
			dest = []any{&row.Distribution, &row.Arch, &row.Vendor, &row.Variant, &row.Version}
		}
		dest = append(dest, counterArgs(&row.UsageCounters)...)
		if err = rows.Scan(dest...); err != nil {
			rows.Close()
			return v, 0, err
		}
		memory += 512 + 2*(len(row.Distribution)+len(row.Arch)+len(row.Vendor)+len(row.Variant)+len(row.Version))
		if memory > usageCacheMaxBytes {
			rows.Close()
			return v, 0, problem("bounded", "Usage selection exceeds the 64 MiB snapshot limit; narrow the filters")
		}
		v.Rows = append(v.Rows, row)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return v, 0, err
	}
	if err = tx.Commit(); err != nil {
		return v, 0, err
	}
	return v, memory, nil
}
