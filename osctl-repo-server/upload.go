package reposerver

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"syscall"
)

type preparedUpload struct {
	ref     FileRef
	path    string
	release func()
}

func (p *preparedUpload) Read([]byte) (int, error) { return 0, io.EOF }

// Reserve complete admitted streams, including bytes not yet written. Counting
// an already-written pending byte again is deliberately conservative: another
// stream must never consume the headroom reserved for database/control writes.
func hasUploadHeadroom(available uint64, size, pending, reserved int64) bool {
	if reserved < 0 || pending < 0 || size < 0 || uint64(reserved) > available {
		return false
	}
	available -= uint64(reserved)
	if uint64(pending) > available {
		return false
	}
	return uint64(size) <= available-uint64(pending)
}

func (s *Store) prepareUpload(ctx context.Context, body io.Reader, p UploadParams) (*preparedUpload, error) {
	if filename(p.Format) == "" || p.Size < 0 || p.Size > s.options.MaxUploadBytes || len(p.SHA256) != 64 {
		return nil, problem("invalid", "invalid upload metadata")
	}
	if _, e := hex.DecodeString(p.SHA256); e != nil {
		return nil, problem("invalid", "invalid checksum")
	}
	s.mu.Lock()
	var used int64
	e := s.db.QueryRowContext(ctx, "SELECT COALESCE(SUM(size),0) FROM files").Scan(&used)
	if e == nil && p.Size > s.options.MaxBytes-used-s.pendingBytes {
		e = problem("quota", "storage quota exceeded")
	}
	var stat syscall.Statfs_t
	if e == nil {
		e = syscall.Statfs(s.options.Root, &stat)
	}
	if e == nil && !hasUploadHeadroom(stat.Bavail*uint64(stat.Bsize), p.Size, s.pendingBytes, s.options.ReservedBytes) {
		e = problem("quota", "reserved filesystem headroom")
	}
	if e != nil {
		s.mu.Unlock()
		return nil, e
	}
	file := id()
	s.pendingBytes += p.Size
	s.activeFiles[file] = true
	modified := s.now()
	s.mu.Unlock()
	prepared := &preparedUpload{ref: FileRef{ID: file, Format: p.Format, SHA256: p.SHA256, Size: p.Size, Modified: modified}, path: filepath.Join(s.options.Root, "files", file)}
	prepared.release = func() {
		s.mu.Lock()
		var count int
		if s.db.QueryRowContext(context.Background(), "SELECT COUNT(*) FROM files WHERE id=?", file).Scan(&count) == nil && count == 0 {
			if e := os.Remove(prepared.path); e == nil {
				syncDir(filepath.Dir(prepared.path))
			}
		}
		delete(s.activeFiles, file)
		s.pendingBytes -= p.Size
		s.mu.Unlock()
	}
	pending := filepath.Join(s.options.Root, "pending", file)
	f, e := os.OpenFile(pending, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if e != nil {
		prepared.release()
		return nil, e
	}
	defer os.Remove(pending)
	hash := sha256.New()
	n, e := io.CopyN(io.MultiWriter(f, hash), body, p.Size)
	if e == nil && (n != p.Size || hex.EncodeToString(hash.Sum(nil)) != p.SHA256) {
		e = problem("integrity", "upload checksum mismatch")
	}
	if e == nil {
		e = f.Sync()
	}
	ce := f.Close()
	if e == nil {
		e = ce
	}
	if e != nil {
		prepared.release()
		return nil, problem("integrity", "upload incomplete or checksum mismatch")
	}
	if e = os.Rename(pending, prepared.path); e == nil {
		e = syncDir(filepath.Dir(prepared.path))
	}
	if e != nil {
		prepared.release()
		return nil, e
	}
	return prepared, nil
}
