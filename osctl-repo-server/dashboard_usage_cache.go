package reposerver

import (
	"context"
	"database/sql"
	"sync"
	"time"
)

const usageCacheMaxBytes = 64 << 20
const usageCacheMaxEntries = 4
const usageReuse = 30 * time.Second
const usageLifetime = 2 * time.Minute

type usageSnapshot struct {
	id, selection string
	created       time.Time
	page          UsagePage
	bytes         int
}

// Only this reader's immutable usage results are retained. The admission channel
// is independent of Store.mu, payload streams and the tiny cache metadata mutex.
type usageResultCache struct {
	mu      sync.Mutex
	cold    chan struct{}
	entries []*usageSnapshot
}

func (c *usageResultCache) prune(now time.Time, retention int) {
	keep := c.entries[:0]
	for _, s := range c.entries {
		if now.Before(s.created.Add(usageLifetime)) && s.page.End.UTC().Format("2006-01-02") == now.UTC().Format("2006-01-02") && s.page.Coverage.RetentionDays == retention {
			keep = append(keep, s)
		}
	}
	clear(c.entries[len(keep):])
	c.entries = keep
}

func (c *usageResultCache) find(selection, token string, now time.Time) *usageSnapshot {
	for i := len(c.entries) - 1; i >= 0; i-- {
		s := c.entries[i]
		if s.selection == selection && (token != "" && s.id == token || token == "" && now.Before(s.created.Add(usageReuse))) {
			return s
		}
	}
	return nil
}

func (d *StoreDashboardReader) cachedUsage(ctx context.Context, q UsageQuery) (UsagePage, error) {
	// The same deadline includes read-pool admission and materializer admission.
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	retention := 365
	err := d.store.reads.QueryRowContext(ctx, "SELECT retention_days FROM http_measurement WHERE repository=? AND instance=?", d.repository, d.instance).Scan(&retention)
	if err != nil && err != sql.ErrNoRows {
		return UsagePage{}, err
	}
	if d.observer != nil {
		retention = d.observer.opts.StatsDays
	}
	now := d.store.now().UTC()
	binding := q
	binding.Cursor = ""
	selection := binding
	selection.Limit = 0
	key := cursorBinding(selection)
	cursor := dashboardCursor{Kind: "usage", Binding: cursorBinding(binding)}
	if q.Cursor != "" {
		cursor, err = decodeDashboardCursor(q.Cursor, "usage", cursor.Binding)
		if err != nil {
			return UsagePage{}, err
		}
		if cursor.Revision == "" || cursor.End.IsZero() {
			return UsagePage{}, problem("invalid", "invalid usage snapshot cursor")
		}
	}
	c := &d.usage
	c.mu.Lock()
	c.prune(now, retention)
	snapshot := c.find(key, cursor.Revision, now)
	if c.cold == nil {
		c.cold = make(chan struct{}, 1)
	}
	admission := c.cold
	c.mu.Unlock()
	if q.Cursor != "" {
		if snapshot == nil || !cursor.End.Equal(snapshot.page.End) {
			return UsagePage{}, problem("conflict", "usage snapshot expired or was evicted; restart pagination")
		}
		return d.usagePage(snapshot, cursor, q.Limit)
	}
	if snapshot != nil {
		return d.usagePage(snapshot, cursor, q.Limit)
	}
	select {
	case admission <- struct{}{}:
		defer func() { <-admission }()
	case <-ctx.Done():
		return UsagePage{}, ctx.Err()
	}
	if err = ctx.Err(); err != nil {
		return UsagePage{}, err
	}
	// A concurrent caller may already have materialized this selection.
	now = d.store.now().UTC()
	c.mu.Lock()
	c.prune(now, retention)
	snapshot = c.find(key, "", now)
	c.mu.Unlock()
	if snapshot == nil {
		page, bytes, e := d.materializeUsage(ctx, q, now)
		if e != nil {
			return UsagePage{}, e
		}
		snapshot = &usageSnapshot{id: id(), selection: key, created: now, page: page, bytes: bytes}
		c.mu.Lock()
		c.prune(now, page.Coverage.RetentionDays)
		used := 0
		for _, entry := range c.entries {
			used += entry.bytes
		}
		for len(c.entries) != 0 && (len(c.entries) >= usageCacheMaxEntries || used+bytes > usageCacheMaxBytes) {
			used -= c.entries[0].bytes
			c.entries[0] = nil
			c.entries = c.entries[1:]
		}
		c.entries = append(c.entries, snapshot)
		c.mu.Unlock()
	}
	return d.usagePage(snapshot, cursor, q.Limit)
}

func (d *StoreDashboardReader) usagePage(s *usageSnapshot, cursor dashboardCursor, limit int) (UsagePage, error) {
	if cursor.Offset > len(s.page.Rows) {
		return UsagePage{}, problem("invalid", "invalid usage cursor offset")
	}
	page := s.page
	page.GeneratedAt = d.store.now()
	page.Coverage.Measurement = d.health()
	// Return bounded copies, so a consumer cannot mutate the retained result.
	page.Days = append([]UsageDay{}, s.page.Days...)
	if page.UpdatedAt != nil {
		value := *page.UpdatedAt
		page.UpdatedAt = &value
	}
	if page.Coverage.RetainedFrom != nil {
		value := *page.Coverage.RetainedFrom
		page.Coverage.RetainedFrom = &value
	}
	end := min(cursor.Offset+limit, len(s.page.Rows))
	page.Rows = append([]UsageRow{}, s.page.Rows[cursor.Offset:end]...)
	page.NextCursor = ""
	if end < len(s.page.Rows) {
		cursor.Revision, cursor.End, cursor.Offset = s.id, s.page.End, end
		page.NextCursor = encodeCursor(cursor)
	}
	return page, nil
}
