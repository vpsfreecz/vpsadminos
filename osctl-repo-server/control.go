package reposerver

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
)

func params(raw json.RawMessage, v any) error {
	d := json.NewDecoder(strings.NewReader(string(raw)))
	d.DisallowUnknownFields()
	if e := d.Decode(v); e != nil {
		return problem("invalid", "invalid command parameters: "+e.Error())
	}
	return nil
}
func canonicalRequest(r Request) (string, error) {
	var value any
	d := json.NewDecoder(strings.NewReader(string(r.Params)))
	d.UseNumber()
	if e := d.Decode(&value); e != nil {
		return "", problem("invalid", "invalid JSON parameters")
	}
	r.Params = encode(value)
	h := sha256.Sum256(encode(r))
	return hex.EncodeToString(h[:]), nil
}
func response(result any, e error) Response {
	if e == nil {
		return Response{OK: true, Result: encode(result)}
	}
	var p *Error
	if !errors.As(e, &p) {
		p = &Error{Code: "internal", Message: "storage operation failed"}
	}
	return Response{Error: p}
}
func permitted(role, op string) bool {
	if role == "admin" {
		return true
	}
	if role == "publisher" {
		return contains([]string{"status", "publish"}, op)
	}
	if role == "producer" {
		return contains([]string{"begin", "status", "renew", "bind", "upload", "result", "finish", "seal"}, op)
	}
	return false
}

// Execute is the only mutation entry point. Role is derived from the protected
// socket, never from the request. One request receipt and state commit together.
func (s *Store) Execute(ctx context.Context, role string, request Request, body io.Reader) Response {
	if !permitted(role, request.Operation) {
		return response(nil, problem("forbidden", "operation not allowed for role"))
	}
	if !component.MatchString(request.Repository) || len(request.Repository) > 128 || request.RequestID == "" || len(request.RequestID) > 128 {
		return response(nil, problem("invalid", "repository/request identity required"))
	}
	digest, e := canonicalRequest(request)
	if e != nil {
		return response(nil, e)
	}
	// Receive/hash/flush outside the catalog mutex: a slow SSH producer must not
	// stall public downloads. Active-file reservations exclude physical reclaim.
	if request.Operation == "upload" {
		var p UploadParams
		if e = params(request.Params, &p); e != nil {
			return response(nil, e)
		}
		// Existing receipt conflicts are detected before consuming another body.
		s.mu.Lock()
		var existing, previous string
		lookup := s.db.QueryRowContext(ctx, "SELECT digest,response FROM requests WHERE role=? AND repository=? AND id=?", role, request.Repository, request.RequestID).Scan(&existing, &previous)
		s.mu.Unlock()
		if lookup == nil && existing != digest {
			return response(nil, problem("conflict", "request ID reused with different content"))
		}
		if lookup == nil {
			h := sha256.New()
			n, e := io.CopyN(h, body, p.Size)
			if e != nil || n != p.Size || hex.EncodeToString(h.Sum(nil)) != p.SHA256 {
				return response(nil, problem("integrity", "retry upload bytes differ"))
			}
			var replay Response
			if e = json.Unmarshal([]byte(previous), &replay); e != nil {
				return response(nil, e)
			}
			return replay
		}
		prepared, e := s.prepareUpload(ctx, body, p)
		if e != nil {
			return response(nil, e)
		}
		defer prepared.release()
		body = prepared
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var previous, stored string
	e = s.db.QueryRowContext(ctx, "SELECT digest,response FROM requests WHERE role=? AND repository=? AND id=?", role, request.Repository, request.RequestID).Scan(&stored, &previous)
	if e == nil {
		if stored != digest {
			return response(nil, problem("conflict", "request ID reused with different content"))
		}
		if request.Operation == "upload" {
			var p UploadParams
			if e = params(request.Params, &p); e != nil {
				return response(nil, e)
			}
			// prepareUpload already verified the entire retry body.
		}
		var r Response
		if e = json.Unmarshal([]byte(previous), &r); e != nil {
			return response(nil, e)
		}
		return r
	}
	if !errors.Is(e, sql.ErrNoRows) {
		return response(nil, e)
	}
	tx, e := s.db.BeginTx(ctx, nil)
	if e != nil {
		return response(nil, e)
	}
	defer func() {
		if tx != nil {
			tx.Rollback()
		}
	}()
	result, e := s.execute(ctx, tx, request, body)
	reply := response(result, e)
	if e != nil {
		tx.Rollback()
		tx, e = s.db.BeginTx(ctx, nil)
		if e != nil {
			return response(nil, e)
		}
	}
	if _, e = tx.ExecContext(ctx, "INSERT INTO requests(role,repository,id,digest,response) VALUES(?,?,?,?,?)", role, request.Repository, request.RequestID, digest, encode(reply)); e != nil {
		tx.Rollback()
		return response(nil, e)
	}
	if e = tx.Commit(); e != nil {
		return response(nil, e)
	}
	if request.Operation == "reclaim" && reply.OK {
		s.unlinkDeleted(ctx)
	}
	return reply
}
func (s *Store) execute(ctx context.Context, tx *sql.Tx, q Request, body io.Reader) (any, error) {
	if q.Operation == "begin" {
		var p BeginParams
		if e := params(q.Params, &p); e != nil {
			return nil, e
		}
		if !component.MatchString(p.ID) || p.Attempt < 1 || !sourceValid(p.Source) || len(p.Expected) > 10000 {
			return nil, problem("invalid", "invalid run plan")
		}
		expires, e := s.lease(p.LeaseSeconds)
		if e != nil {
			return nil, e
		}
		var active int
		if e = tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM runs WHERE json_extract(document,'$.state')!='expired'").Scan(&active); e != nil {
			return nil, e
		}
		if active >= s.options.MaxRuns {
			return nil, problem("quota", "run admission quota")
		}
		baseline, e := s.ensureRepo(ctx, tx, q.Repository)
		if e != nil {
			return nil, e
		}
		key := hex.EncodeToString(encode([]any{q.Repository, p.ID, p.Attempt}))
		var already int
		if e = tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM runs WHERE key=?", key).Scan(&already); e != nil {
			return nil, e
		}
		if already != 0 {
			return nil, problem("conflict", "run identity already admitted")
		}
		seen := map[string]bool{}
		for i := range p.Expected {
			item := &p.Expected[i]
			if !component.MatchString(item.ID) || seen[item.ID] || item.Order < 0 {
				return nil, problem("invalid", "invalid work item")
			}
			seen[item.ID] = true
			for _, tag := range item.Tags {
				if !component.MatchString(tag) {
					return nil, problem("invalid", "invalid tag")
				}
			}
			item.State = "queued"
			item.Attempt = 0
			item.Descriptor = nil
			item.Files = nil
			item.Message = ""
		}
		// Admission order is durable, independent of caller timestamps.
		var admission int64
		if e = tx.QueryRowContext(ctx, "SELECT COALESCE(MAX(json_extract(document,'$.admission')),0)+1 FROM runs").Scan(&admission); e != nil {
			return nil, e
		}
		r := runRecord{RunSummary: RunSummary{Key: key, Repository: q.Repository, ID: p.ID, Attempt: p.Attempt, State: "open", Source: p.Source, Expires: expires, Items: p.Expected}, Baseline: baseline, Admission: admission, Defaults: p.Defaults}
		_, e = tx.ExecContext(ctx, "INSERT INTO runs(key,repository,document) VALUES(?,?,?)", key, q.Repository, encode(r))
		return r.RunSummary, e
	}
	if q.Operation == "status" {
		if q.RunKey != "" {
			r, e := loadRun(ctx, tx, q.RunKey, q.Repository)
			return r.RunSummary, e
		}
		return s.catalog(ctx, tx, q.Repository, "")
	}
	if q.Operation == "reclaim" {
		return s.markReclaim(ctx, tx)
	}
	if q.Operation == "import-legacy" || q.Operation == "import-generation" || q.Operation == "export" || q.Operation == "export-legacy" {
		return s.transfer(ctx, tx, q, body)
	}
	if q.Operation == "expire" {
		if q.RunKey == "" {
			rows, e := tx.QueryContext(ctx, "SELECT key,repository FROM runs WHERE repository=?", q.Repository)
			if e != nil {
				return nil, e
			}
			type pair struct{ k, r string }
			list := []pair{}
			for rows.Next() {
				var p pair
				if e = rows.Scan(&p.k, &p.r); e != nil {
					rows.Close()
					return nil, e
				}
				list = append(list, p)
			}
			rows.Close()
			count := 0
			for _, p := range list {
				r, e := loadRun(ctx, tx, p.k, p.r)
				if e != nil {
					return nil, e
				}
				if r.State != "expired" && !r.Expires.After(s.now()) {
					r.State = "expired"
					r.Baseline = ""
					r.Generation = ""
					if e = saveRun(ctx, tx, r); e != nil {
						return nil, e
					}
					count++
				}
			}
			return map[string]int{"expired": count}, nil
		}
	}
	r, e := loadRun(ctx, tx, q.RunKey, q.Repository)
	if e != nil {
		return nil, e
	}
	if q.Operation == "expire" {
		if r.Expires.After(s.now()) {
			return nil, problem("conflict", "run lease still active")
		}
		r.State = "expired"
		r.Baseline = ""
		r.Generation = ""
		return r.RunSummary, saveRun(ctx, tx, r)
	}
	if r.State == "expired" || !r.Expires.After(s.now()) {
		return nil, problem("expired", "run lease expired")
	}
	switch q.Operation {
	case "renew":
		var p struct {
			LeaseSeconds int64 `json:"lease_seconds"`
		}
		if e = params(q.Params, &p); e != nil {
			return nil, e
		}
		r.Expires, e = s.lease(p.LeaseSeconds)
		if e != nil {
			return nil, e
		}
	case "bind":
		if e = requireRunOpen(r, s.now()); e != nil {
			return nil, e
		}
		var p BindParams
		if e = params(q.Params, &p); e != nil {
			return nil, e
		}
		item, e := findItem(&r, p.ItemID)
		if e != nil {
			return nil, e
		}
		if !p.Descriptor.Tuple.valid() || p.Descriptor.ConfigDigest == "" || len(p.Descriptor.ConfigDigest) > 256 || p.Attempt != item.Attempt+1 || item.State == "verified" || len(p.Descriptor.Formats) == 0 {
			return nil, problem("conflict", "invalid assignment or attempt")
		}
		seen := map[string]bool{}
		for _, f := range p.Descriptor.Formats {
			if filename(f) == "" || seen[f] {
				return nil, problem("invalid", "invalid declared format")
			}
			seen[f] = true
		}
		if item.Descriptor != nil && string(encode(*item.Descriptor)) != string(encode(p.Descriptor)) {
			return nil, problem("conflict", "retry changes assigned descriptor")
		}
		for _, other := range r.Items {
			if other.ID != item.ID && other.Descriptor != nil && other.Descriptor.Tuple == p.Descriptor.Tuple {
				return nil, problem("conflict", "tuple assigned twice")
			}
		}
		item.Attempt = p.Attempt
		item.Descriptor = &p.Descriptor
		item.State = "running"
		item.Files = map[string]FileRef{}
		item.Message = ""
	case "upload":
		if e = requireRunOpen(r, s.now()); e != nil {
			return nil, e
		}
		var p UploadParams
		if e = params(q.Params, &p); e != nil {
			return nil, e
		}
		item, e := findItem(&r, p.ItemID)
		if e != nil {
			return nil, e
		}
		if item.State != "running" || item.Attempt != p.Attempt || item.Descriptor == nil || !contains(item.Descriptor.Formats, p.Format) {
			return nil, problem("conflict", "upload not assigned to active item")
		}
		if _, exists := item.Files[p.Format]; exists {
			return nil, problem("conflict", "format already uploaded; retry original request")
		}
		ref, e := s.commitFile(ctx, tx, body, p.Format, p.SHA256, p.Size)
		if e != nil {
			return nil, e
		}
		if item.Files == nil {
			item.Files = map[string]FileRef{}
		}
		item.Files[p.Format] = ref
	case "result":
		if e = requireRunOpen(r, s.now()); e != nil {
			return nil, e
		}
		var p ResultParams
		if e = params(q.Params, &p); e != nil {
			return nil, e
		}
		item, e := findItem(&r, p.ItemID)
		if e != nil {
			return nil, e
		}
		if item.State == "queued" && item.Descriptor == nil && p.Attempt == 0 && p.ConfigDigest == "" && (p.State == "failed" || p.State == "cancelled") && len(p.Message) <= 2048 {
			item.State, item.Message = p.State, p.Message
			break
		}
		if item.State != "running" || item.Attempt != p.Attempt || item.Descriptor == nil || p.ConfigDigest != item.Descriptor.ConfigDigest {
			return nil, problem("conflict", "result does not match active assignment")
		}
		if !contains([]string{"verified", "failed", "cancelled"}, p.State) || len(p.Message) > 2048 {
			return nil, problem("invalid", "invalid result")
		}
		if p.State == "verified" {
			if !p.BuildOK || !p.TestsOK {
				return nil, problem("integrity", "successful build and tests required")
			}
			for _, format := range item.Descriptor.Formats {
				if _, exists := item.Files[format]; !exists {
					return nil, problem("integrity", "declared format not uploaded")
				}
			}
		}
		item.State = p.State
		item.Message = p.Message
	case "finish":
		if r.State != "open" {
			return nil, problem("conflict", "run already finished")
		}
		for i := range r.Items {
			if r.Items[i].State == "queued" || r.Items[i].State == "running" {
				r.Items[i].State = "failed"
				r.Items[i].Message = "interrupted before finish"
			}
		}
		r.State = "finished"
	case "seal":
		if r.State != "finished" {
			return nil, problem("conflict", "finish run before seal")
		}
		v, e := loadCatalog(ctx, tx, r.Baseline)
		if e != nil {
			return nil, e
		}
		c := v.Catalog
		if r.Defaults != nil {
			c.Vendors = r.Defaults
		}
		for _, item := range orderedItems(r) {
			if item.State != "verified" || item.Descriptor == nil {
				return nil, problem("not_ready", "expected work is not verified")
			}
			addImage(&c, imageFor(r, item))
		}
		if _, e = s.catalogReferences(ctx, tx, c); e != nil {
			return nil, e
		}
		v, e = s.saveCatalog(ctx, tx, q.Repository, "", c)
		if e != nil {
			return nil, e
		}
		r.State = "sealed"
		r.Generation = v.Generation
		if e = saveRun(ctx, tx, r); e != nil {
			return nil, e
		}
		v.Scope = "run"
		v.RunKey = r.Key
		return v, nil
	case "publish":
		return s.publish(ctx, tx, q, r)
	default:
		return nil, problem("invalid", "unknown operation")
	}
	if e = saveRun(ctx, tx, r); e != nil {
		return nil, e
	}
	return r.RunSummary, nil
}
func imageFor(r runRecord, item WorkItem) Image {
	return Image{Tuple: item.Descriptor.Tuple, Tags: item.Tags, Files: item.Files, Source: r.Source.SHA, Admission: r.Admission}
}
func (s *Store) publish(ctx context.Context, tx *sql.Tx, q Request, r runRecord) (any, error) {
	var p PublishParams
	if e := params(q.Params, &p); e != nil {
		return nil, e
	}
	v, e := s.catalog(ctx, tx, q.Repository, "")
	if e != nil {
		return nil, e
	}
	if p.Generation != v.Generation {
		return nil, problem("conflict", "public generation advanced")
	}
	c := v.Catalog
	if len(p.Items) == 0 && len(p.Superseded) > 0 {
		seen := map[string]bool{}
		for _, name := range p.Superseded {
			if seen[name] {
				return nil, problem("invalid", "duplicate superseded item")
			}
			seen[name] = true
			if _, e = findItem(&r, name); e != nil {
				return nil, e
			}
		}
		return map[string]any{"generation": v.Generation, "updated": []string{}, "failed": []string{}, "superseded": p.Superseded, "pruned": []Tuple{}}, nil
	}
	// The protected publisher supplies Git ancestry proofs, bound to this exact
	// generation. Metadata cannot authorize publication through a producer socket.
	canAdvance := func(old string, admission int64) bool {
		if old == r.Source.SHA {
			return admission <= r.Admission
		}
		return old == "" || contains(p.Ancestors, old)
	}
	if !canAdvance(c.PolicySource, c.PolicyAdmission) {
		if c.PolicySource == r.Source.SHA && c.PolicyAdmission > r.Admission {
			return nil, problem("superseded", "newer same-source run already published")
		}
		return nil, problem("conflict", "publication policy superseded or ancestry unavailable")
	}
	updated := []string{}
	superseded := []string{}
	seen := map[string]bool{}
	for _, name := range append(append([]string{}, p.Items...), p.Superseded...) {
		if seen[name] {
			return nil, problem("invalid", "duplicate publication item")
		}
		seen[name] = true
		if _, e = findItem(&r, name); e != nil {
			return nil, e
		}
	}
	for _, item := range orderedItems(r) {
		if contains(p.Superseded, item.ID) {
			superseded = append(superseded, item.ID)
			continue
		}
		if !contains(p.Items, item.ID) {
			continue
		}
		if item.State != "verified" || item.Descriptor == nil {
			return nil, problem("integrity", "only verified receipts can publish")
		}
		newer := false
		for _, old := range c.Images {
			if old.Tuple == item.Descriptor.Tuple && !canAdvance(old.Source, old.Admission) {
				newer = true
				break
			}
		}
		if newer {
			return nil, problem("conflict", "tuple ancestry missing or superseded")
		}
		addImage(&c, imageFor(r, item))
		updated = append(updated, item.ID)
	}
	if p.Defaults == nil {
		return nil, problem("invalid", "authorized defaults required")
	}
	c.Vendors = p.Defaults
	c.PolicySource = r.Source.SHA
	c.PolicyAdmission = r.Admission
	pruned, e := ApplyGC(&c, p.GC)
	if e != nil {
		return nil, e
	}
	if _, e = s.catalogReferences(ctx, tx, c); e != nil {
		return nil, e
	}
	nv, e := s.saveCatalog(ctx, tx, q.Repository, "", c)
	if e != nil {
		return nil, e
	}
	if _, e = tx.ExecContext(ctx, "UPDATE repositories SET generation=? WHERE id=? AND generation=?", nv.Generation, q.Repository, p.Generation); e != nil {
		return nil, e
	}
	if _, e = tx.ExecContext(ctx, "UPDATE catalogs SET retain_until=? WHERE id=?", s.now().Add(s.options.ExportLease).Unix(), p.Generation); e != nil {
		return nil, e
	}
	failed := []string{}
	for _, item := range r.Items {
		if item.State != "verified" {
			failed = append(failed, item.ID)
		}
	}
	return map[string]any{"generation": nv.Generation, "updated": updated, "failed": failed, "superseded": superseded, "pruned": pruned}, nil
}

func (s *Store) markReclaim(ctx context.Context, tx *sql.Tx) (any, error) {
	now := s.now().Unix()
	if _, e := tx.ExecContext(ctx, "DELETE FROM transfers WHERE expires<=?", now); e != nil {
		return nil, e
	}
	rows, e := tx.QueryContext(ctx, "SELECT document FROM runs")
	if e != nil {
		return nil, e
	}
	keep := map[string]bool{}
	for rows.Next() {
		var b []byte
		var r runRecord
		if e = rows.Scan(&b); e != nil {
			rows.Close()
			return nil, e
		}
		if e = json.Unmarshal(b, &r); e != nil {
			rows.Close()
			return nil, e
		}
		if r.State != "expired" {
			keep[r.Baseline] = true
			keep[r.Generation] = true
		}
	}
	rows.Close()
	rows, e = tx.QueryContext(ctx, "SELECT id FROM catalogs WHERE retain_until<=? AND id NOT IN(SELECT generation FROM repositories) AND id NOT IN(SELECT generation FROM transfers)", now)
	if e != nil {
		return nil, e
	}
	remove := []string{}
	for rows.Next() {
		var gen string
		if e = rows.Scan(&gen); e != nil {
			rows.Close()
			return nil, e
		}
		if !keep[gen] {
			remove = append(remove, gen)
		}
	}
	rows.Close()
	for _, gen := range remove {
		if _, e = tx.ExecContext(ctx, "DELETE FROM catalogs WHERE id=?", gen); e != nil {
			return nil, e
		}
	}
	result, e := tx.ExecContext(ctx, "UPDATE files SET state='deleting' WHERE state='ready' AND id NOT IN(SELECT file FROM refs) AND id NOT IN(SELECT file FROM run_files)")
	if e != nil {
		return nil, e
	}
	n, e := result.RowsAffected()
	return map[string]int64{"marked": n}, e
}
func (s *Store) unlinkDeleted(ctx context.Context) {
	rows, e := s.db.QueryContext(ctx, "SELECT id,path FROM files WHERE state='deleting'")
	if e != nil {
		return
	}
	type entry struct{ id, path string }
	list := []entry{}
	for rows.Next() {
		var v entry
		if rows.Scan(&v.id, &v.path) != nil {
			rows.Close()
			return
		}
		list = append(list, v)
	}
	rows.Close()
	for _, v := range list {
		if e = os.Remove(v.path); e != nil && !errors.Is(e, os.ErrNotExist) {
			continue
		}
		if e = syncDir(filepath.Dir(v.path)); e != nil {
			continue
		}
		s.db.ExecContext(ctx, "DELETE FROM files WHERE id=? AND state='deleting'", v.id)
	}
	// Durable final files left by an interrupted pre-DB commit have no row.
	entries, e := os.ReadDir(filepath.Join(s.options.Root, "files"))
	if e != nil {
		return
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		var count int
		if s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM files WHERE id=?", entry.Name()).Scan(&count) == nil && count == 0 && !s.activeFiles[entry.Name()] {
			os.Remove(filepath.Join(s.options.Root, "files", entry.Name()))
		}
	}
}
