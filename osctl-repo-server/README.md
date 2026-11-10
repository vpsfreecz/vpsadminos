# osctl-repo-server

One local owner serves v1 public and sealed run repositories. Immutable ordinary
files hold image bytes; SQLite holds catalogs, run state and request receipts.
The database upgrades supported schema 1 to schema 2 transactionally. Schema 1
is deployed state and must be retained through upgrade and recovery. Public
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
not block public file lookup. A separate read-only WAL pool uses at most two
connections for public queries. Payload streaming never holds the store admission
mutex; the open inode remains pinned across later publication and reclamation.

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
Fresh databases initialize the retained schema-1 definition and then follow the
same ordered schema-1-to-2 conversion as an existing database.

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

## Schema 1 to 2 upgrade and recovery

The database is `ROOT/catalog.sqlite`, with SQLite WAL sidecars
`catalog.sqlite-wal` and `catalog.sqlite-shm`. `ROOT/writer.lock` excludes concurrent
owners. Version checks and the complete upgrade run under exclusive startup
ownership, before pending-upload cleanup, read-pool creation or listeners.
Unknown future versions are rejected before database mutation or cleanup.

The conversion adds typed daily dimensions, indexes and small measurement
metadata. It preserves every original daily dimension, request count and byte
count, including categories outside the new usage subset. Catalogs, runs,
receipts, replay identities, file IDs, payload references, provenance and GC
references stay unchanged. Payload files are not rewritten. Invalid historical
dimensions/dates or SQL conversion failure roll back every schema change and the
version marker. Reopening schema 2 does not repeat conversion.

Before starting the upgraded service, block new producer, publisher and
administrator writes, then drain HTTP requests and telemetry. Stop the old owner, checkpoint SQLite, and
retain a coherent pre-upgrade SQLite backup together with every referenced
immutable payload, service configuration and private ownership/permissions.
Verify recovery against a separate copy before selecting the upgraded owner.
An old schema-1 binary rejects schema 2. Recovery means restoring the coherent
pre-upgrade database and payload set, not changing `user_version` or resetting the
database. Once new writes occur, prefer forward recovery or explicitly reconcile
that newer state before restoring an older backup. Site-specific activation and
recovery ordering belongs to the owning configuration repository.

## Bounded public reads and usage accounting

`DashboardReader` in `dashboard_read.go` adds repository/instance-bound overview,
catalog and usage queries without changing the legacy Reader, control protocol,
v1 paths or the complete `dashboard.json` response. The new GET/HEAD JSON endpoints
are `/dashboard/api/overview`, `/dashboard/api/catalog` and `/dashboard/api/usage`.

Catalog hierarchy pages traverse distribution, architecture, vendor/variant,
then version. Each level requires exactly its parent selectors. Default page
size is 50, maximum 100. Invalid filters/cursors are 400; replaced catalog or
statistics cursors are 409 with a restart instruction. Database/read failure is
503. Small pages do not construct the legacy full dashboard. Two immutable
catalog generations share a bounded 64 MiB lookup/INDEX/hierarchy cache; warm
requests reuse encoded INDEX bytes, validators and lexical hierarchy rows.
The summary cache lasts at most two seconds. Every artifact lookup rechecks the
selected public mapping or run lease before opening under the reference boundary;
cached entries cannot authorize an expired run or replaced public file.

Usage periods `today`, `7d`, `30d` and `365d` run from UTC midnight to the
time of the request:
today is a partial day; the others include N-1 preceding UTC days. These are
rolling daily windows, not calendar months/years. SQL aggregates indexed typed
daily dimensions; totals and daily buckets cover the entire exact filter,
independently of the ranked row page. Usage cursors bind window, filters, ordering
and the committed statistics revision, so refresh invalidates stale pages.

Only public artifact responses enter usage. Full downloads are completed GET
200 responses, not successful imports or unique people. GET 206 range responses
are counted separately. Transferred bytes count response-body bytes written for
image GET 200/206 requests, including partial interrupted transfers and multipart
range framing. HTTP headers, HEAD, 304, INDEX, dashboard and error-page bytes are
excluded. Interruptions and errors have
separate request counters. Retries are new requests. UTC day assignment remains
the original request-start timestamp. Legacy aggregate categories and counters
remain exact and readable through `dashboard.json`.

The normal `--stats-days` default is 365. Explicit shorter limits remain honored;
increasing the limit cannot recover deleted observations. Coverage reports
retention, earliest retained observation, last update and measurement health.
History completeness remains unknown rather than treating absent old rows as
zero traffic. Existing bounded row quotas still apply; exceeding them records
measurement failure rather than claiming complete yearly totals.

The bounded nonblocking event queue batches up to 128 events into short SQLite
transactions and combines identical daily increments. Retention and quota checks
run per batch; public snapshots refresh at least once per second of sustained
processing and after drain. Private log failures do not skip statistics updates.
Overload, database failure or a process crash can lose measurements. Drop and
failure counters expose gaps; statistics are not guaranteed to survive a crash. Slow telemetry never applies
backpressure to payload streams. No requester address, user agent, query string,
run identity or private path appears in public dimensions or usage responses.
