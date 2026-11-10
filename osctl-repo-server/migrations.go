package reposerver

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"time"
)

// Schema 1 is deployed and remains the only supported predecessor. Keep its
// original definition in store.go; fresh stores follow this same upgrade.
func migrateSchema1(ctx context.Context, db *sql.DB) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	columns := []string{"scope", "kind", "distribution", "arch", "vendor", "variant", "version", "format", "method", "outcome"}
	for _, c := range columns {
		if _, err = tx.ExecContext(ctx, "ALTER TABLE http_daily ADD COLUMN "+c+" TEXT NOT NULL DEFAULT ''"); err != nil {
			return err
		}
	}
	if _, err = tx.ExecContext(ctx, "ALTER TABLE http_daily ADD COLUMN status INTEGER NOT NULL DEFAULT 0"); err != nil {
		return err
	}
	rows, err := tx.QueryContext(ctx, "SELECT repository,instance,day,dimensions FROM http_daily")
	if err != nil {
		return err
	}
	type row struct {
		repo, instance, day, key string
		dim                      AggregateKey
	}
	var records []row
	for rows.Next() {
		var r row
		if err = rows.Scan(&r.repo, &r.instance, &r.day, &r.key); err != nil {
			rows.Close()
			return err
		}
		dec := json.NewDecoder(strings.NewReader(r.key))
		dec.DisallowUnknownFields()
		if err = dec.Decode(&r.dim); err != nil {
			rows.Close()
			return fmt.Errorf("schema 1 daily dimensions (%s): %w", r.day, err)
		}
		var extra any
		if err = dec.Decode(&extra); err != io.EOF {
			rows.Close()
			return fmt.Errorf("schema 1 daily dimensions contain trailing data")
		}
		if !strings.HasPrefix(strings.TrimSpace(r.key), "{") {
			rows.Close()
			return fmt.Errorf("schema 1 daily dimensions must be an object")
		}
		if _, err = time.Parse("2006-01-02", r.day); err != nil {
			rows.Close()
			return fmt.Errorf("schema 1 daily date: %w", err)
		}
		records = append(records, r)
	}
	if err = rows.Err(); err != nil {
		rows.Close()
		return err
	}
	rows.Close()
	for _, r := range records {
		k := r.dim
		_, err = tx.ExecContext(ctx, `UPDATE http_daily SET scope=?,kind=?,distribution=?,arch=?,vendor=?,variant=?,version=?,format=?,method=?,outcome=?,status=? WHERE repository=? AND instance=? AND day=? AND dimensions=?`, k.Scope, k.Kind, k.Tuple.Distribution, k.Tuple.Arch, k.Tuple.Vendor, k.Tuple.Variant, k.Tuple.Version, k.Format, k.Method, k.Outcome, k.Status, r.repo, r.instance, r.day, r.key)
		if err != nil {
			return err
		}
	}
	_, err = tx.ExecContext(ctx, `CREATE INDEX http_daily_usage ON http_daily(repository,instance,scope,kind,day,distribution,arch,vendor,variant,version);
 CREATE TABLE http_measurement (repository TEXT NOT NULL, instance TEXT NOT NULL, retention_days INTEGER NOT NULL, revision INTEGER NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY(repository,instance));
 INSERT INTO http_measurement SELECT repository,instance,365,0,max(day)||'T00:00:00Z' FROM http_daily GROUP BY repository,instance;
 CREATE INDEX runs_repository ON runs(repository);
 PRAGMA user_version=2;`)
	if err != nil {
		return err
	}
	return tx.Commit()
}
