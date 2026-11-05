package reposerver

import (
	"context"
	"encoding/json"
	"fmt"
)

func (s *Store) RecordHTTP(ctx context.Context, e AccessEvent, days, maxRows int) error {
	if days < 1 || maxRows < 1 {
		return fmt.Errorf("statistics need finite bounds")
	}
	dimensions, err := json.Marshal(aggregateKey(e))
	if err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	day := e.Timestamp.UTC().Format("2006-01-02")
	cutoff := e.Timestamp.UTC().AddDate(0, 0, -days+1).Format("2006-01-02")
	if _, err = tx.ExecContext(ctx, "DELETE FROM http_daily WHERE repository=? AND instance=? AND day<?", e.Repository, e.Instance, cutoff); err != nil {
		return err
	}
	var rows int
	if err = tx.QueryRowContext(ctx, "SELECT count(*) FROM http_daily WHERE repository=? AND instance=?", e.Repository, e.Instance).Scan(&rows); err != nil {
		return err
	}
	if rows >= maxRows {
		var exists int
		if err = tx.QueryRowContext(ctx, "SELECT count(*) FROM http_daily WHERE repository=? AND instance=? AND day=? AND dimensions=?", e.Repository, e.Instance, day, string(dimensions)).Scan(&exists); err != nil {
			return err
		}
		if exists == 0 {
			return fmt.Errorf("statistics row limit reached")
		}
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO http_daily(repository,instance,day,dimensions,requests,bytes) VALUES(?,?,?,?,1,?)
ON CONFLICT(repository,instance,day,dimensions) DO UPDATE SET requests=requests+1,bytes=bytes+excluded.bytes`, e.Repository, e.Instance, day, string(dimensions), e.Bytes)
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) HTTPStatistics(ctx context.Context, repository, instance string) ([]DailyStatistic, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT day,dimensions,requests,bytes FROM http_daily WHERE repository=? AND instance=? ORDER BY day DESC,dimensions", repository, instance)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	stats := []DailyStatistic{}
	for rows.Next() {
		var stat DailyStatistic
		var key string
		if err := rows.Scan(&stat.Day, &key, &stat.Requests, &stat.Bytes); err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(key), &stat.AggregateKey); err != nil {
			return nil, err
		}
		stats = append(stats, stat)
	}
	return stats, rows.Err()
}
