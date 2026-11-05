# osctl-repo-server

One local owner serves v1 public and sealed run repositories. Immutable ordinary
files hold image bytes; SQLite holds catalogs, run state and request receipts.
The initial database schema is version 1, new, unreleased and undeployed. Public
clients keep the existing HTTP repository protocol. Native local writers and
legacy rsync must be excluded before adopting their files.

## Control wire (version 1)

`osctl-repo-server ctl --socket PATH` forwards standard input to a role-specific
local Unix socket and prints one JSON response. SSH forced commands choose this
socket; callers cannot grant themselves publisher authority in JSON. Three sockets
have producer, publisher and administrator authority respectively. Site configuration
must restrict their filesystem access to the matching trusted principals.

Input begins with one JSON line (`Request` in `types.go`):

```json
{"request_id":"stable-unique-id","operation":"begin","repository":"vpsadminos","params":{"id":"github-run-123","attempt":1,"source":{"sha":"full-source-sha","input_digest":"resolved-input-digest","ref":"refs/heads/staging","event":"push"},"expected":[{"id":"debian-13","order":0,"tags":["latest","stable"]}],"lease_seconds":86400}}
```

Response is `{"ok":true,"result":...}` or
`{"ok":false,"error":{"code":"conflict","message":"..."}}`. Begin returns
`RunSummary` including opaque `key`; all subsequent operations supply it as
`run_key`. URLs put that opaque key in `/runs/<key>/v1/...`. `repository` is always
required. Public `status` without run key returns `CatalogView`; run status returns
`RunSummary`. `types.go` is the authoritative compiled field contract.

| operation | params / meaning |
| --- | --- |
| `begin` | `BeginParams`; expected IDs/order/tags only, all initially queued. Pins current public baseline. |
| `bind` | `BindParams`: item_id, attempt, descriptor with vendor/variant/arch/distribution/version, formats (`tar`,`zfs`), config_digest. Freeze actual resolved identity before build. Item becomes running. Retry increments attempt, retains descriptor. |
| `upload` | `UploadParams`: item_id, attempt, format, sha256, size. Exactly `size` binary bytes follow the JSON newline. Separate upload per format; server verifies and commits durable immutable bytes before reference. |
| `result` | `ResultParams`: same item_id/attempt/config_digest; state `verified` requires build_ok/tests_ok and every declared uploaded format; alternatively `failed`/`cancelled` with bounded message. |
| `renew` | `{"lease_seconds":N}` within configured maximum; applies to unexpired run. |
| `finish` | `{}`; freezes run outcomes, running/queued become interrupted (`failed`). Never implies seal/publish success. |
| `seal` | `{}`; finished run requires every expected item verified. Returns immutable run catalog/view; failure leaves independent good receipts intact. |
| `publish` | `PublishParams`; publisher only. generation is the fresh public generation, items are verified item IDs, defaults and exact GC rules from authorized source, ancestors lists current older source SHAs proven ancestors of this run SHA by protected publisher. A stale generation conflicts. Equal-source earlier admission is superseded. No ancestry proof means fail closed; claimed source alone grants no authority. |
| `expire` | `{}`; administrator only, removes expired run references; cannot silently expire active lease. |
| `reclaim` | `{}`; administrator only, physical orphan/unreferenced cleanup. |
| `import-legacy` | Administrator only, `{"path":"/absolute/repository","generation":"expected-current-or-empty"}`; coherent native tree with `v1/INDEX.json`. Hashes/adopts existing regular files in place after the operator excludes every old writer. |
| `export` | Administrator only, `{"path":"/absolute/new-directory","lease_seconds":N}`; verified public `manifest.json` and `files/<stable-file-id>`. Does not include private runs or logs. |
| `export-legacy` | Administrator only, same new path parameter; materialize current public `v1` files/INDEX/default/tag symlinks for reconciled static-service recovery. |
| `import-generation` | Administrator only, same path/generation parameters; verify complete portable bytes and manifest before selecting public state. |

Every mutation's request ID is scoped to role+repository and bound to a canonical
JSON digest. Identical retries replay the durable response; changed content with
the same ID conflicts. Upload digest includes claimed hash/size; replay still
checks incoming bytes. Unknown IDs, stale attempts and bad integrity fail explicitly.
Producer role cannot publish/import/expire/reclaim. Publisher does not replace
the trusted CI job's source/ref/ancestry admission checks.

Publication returns `superseded` when a later-admitted run of the same source
already owns the public policy. The caller can record a fresh-generation
superseded-only request without applying any old defaults or GC. Generation races
and unavailable non-equal-source ancestry remain `conflict`.

Expected changed slots require their same-run verified receipt: baseline files
never satisfy them. Finish and publication are independent, so good default-source
items can publish despite unrelated failed selected builds or full CI failure.
Apply successful items in frozen configured order, independent of upload order.
No public mutations are exposed over the public HTTP listener.

Reader interface and DTOs are in `types.go`. Empty run key selects public; runs
before seal fail `not_ready`, expired runs `expired`, unknown paths `not_found`.
`OpenFile` opens under the store's reference boundary and hands the HTTP owner an
open inode; close it after serving. Canonical and documented alias resolution use
catalog metadata. Sealed run metadata and validators never change.

## Running and storage

Build through `nix build .#osctl-repo-server`; develop/check through
`nix develop .#osctl-repo-server --command bash -c 'cd osctl-repo-server && go test ./... && go vet ./...'`.
The SQLite driver uses CGO and the declared shell includes the C compiler.
Run `osctl-repo-server serve` with explicit bounds and paths; no capacity values
are inferred from a development fixture:

- `--root`, `--listen`, `--repository`, `--instance`;
- `--producer-socket`, `--publisher-socket`, `--admin-socket`, with matching
  `--producer-group`, `--publisher-group`, `--admin-group` OS group names;
- `--max-bytes`, `--reserve-bytes`, `--max-upload-bytes`, `--max-runs`,
  `--max-lease`, `--export-lease` (duration flags such as `24h`);
- `--access-log`, `--access-log-max-bytes`, `--access-log-files`, `--stats-days`,
  `--stats-max-rows`, `--event-queue`, `--client-ip-header`, and repeatable
  `--trusted-proxy` network prefixes.

The root and immutable/pending file directories are private. A process lock
excludes a second writer. SQLite enforces foreign keys, WAL and FULL synchronous
commits. Uploads reserve space, stream/hash/flush outside the catalog lock, rename
and flush the destination directory before references commit. Slow producers do
not block public file lookup. Initial schema 1 has no previous supported format;
reset stale disposable fixture databases rather than adding migration guards.

Logical GC operates only on public catalog metadata, preserving configured native
matching/group/order/count semantics. Supported patterns use Go's regular-expression
syntax with Ruby's ASCII `\d` translated; unsupported constructs fail closed.
Active run, public, export and bounded rollback references retain immutable bytes.
The administrator schedules `expire` and `reclaim` through the control socket;
run leases must expire before their references can be removed. Reclamation marks
files unavailable before unlink, retries failed unlinks and protects open readers.
Restart clears incomplete pending uploads under exclusive ownership; final files
with no committed reference are reclaimed by maintenance. Never modify managed
files in place, including adopted legacy paths.

Admission reserves each complete pending stream against both the payload quota
and filesystem headroom before reading it. Already-written pending bytes may be
counted again conservatively until the stream commits/releases its reservation.
The initial schema and version marker are created in one SQLite transaction.

Sealing and publication validate catalog shape and references against the stored
verified file identities, without rereading all unchanged payload bytes under
the reader lock. Upload/adoption/import verify bytes before those identities are
committed; export verifies them again while producing recovery/transfer material.

Portable export directories are administrator-owned outputs. Stable generation
and file IDs are independent of SQLite row IDs and local source paths. Verify
hashes when restoring. Back up the SQLite metadata together with every retained
file path; copying only the DB does not preserve images. Restoring a static
repository needs a validated materialization of current public state, not the old
rsync source. Site activation and rollback belong to the configuration repository.

See [HTTP and logging](HTTP.md) for reader, cache, private log and aggregate details.
