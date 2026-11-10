# HTTP serving and request measurements

The public listener serves one configured repository. It has no mutation API.
Control operations use the separate role sockets described in [README](README.md).
`Reader` and `CatalogView` in [types.go](types.go) define the internal reader boundary.
The handler closes each opened file after serving; an open inode remains readable
while the catalog changes or removes its reference.

## Repository URLs and validators

`/v1/INDEX.json` uses the native JSON vendors/images/tags/image format mapping,
including only the formats present in each image. Images keep native tuple-string
order. Canonical files and vendor/variant/tag aliases stream from catalog metadata
without redirects. `/runs/<key>/v1/` has the same layout for a sealed run. Unknown
paths return 404, unsealed views 503 with Retry-After, and expired runs 410.
No missing candidate falls back to current public files.

GET and HEAD have matching content length and file metadata. Byte ranges produce
206 and Content-Range; identity bytes are unchanged. File ETags bind immutable
file identity and hash, and INDEX ETags bind its actual JSON bytes. Last-Modified
is available for native clients. Sealed views support date validation and 304.
Public date checks return a conservative 200 because HTTP dates cannot distinguish
same-second replacement or rollback. Public date-based If-Range also returns the
complete current file; strong ETags can validate or select a range safely.

`/` and `/v1/` provide the vpsAdminOS image dashboard. Catalog directories and
sealed-run directories retain their image links.
`/dashboard.json` provides its aggregate data without requester fields. Dashboard
responses use no-store; repository responses require revalidation. Keep every
artifact route through the handler, including aliases, rather than adding a
static fallback that exposes files pruned from the public catalog.

## Public statistics

The dashboard identifies vpsAdminOS and links to the project, documentation and
source. Images are grouped by distribution, architecture, vendor/variant, then
version. Each ordinary navigation link loads at most 50 groups or versions;
next-page links retain the selection. Downloads keep their canonical file URLs.
The initial HTML does not embed the complete catalog or fetch the legacy
`/dashboard.json` response. The legacy JSON response remains complete.

Usage starts with the last seven UTC days of public image traffic. Today,
Last 7 days, Last 30 days and Last 365 days links use rolling day windows, with
the exact start/end, latest measurement and retained-history coverage shown.
Distribution, architecture and exact image/variant links narrow the totals.
Ranked rows are paged; daily totals cover the whole selection and contain at
most 365 rows. Expired cursors ask the reader to restart rather than mixing
pages. Unavailable measurements show an error rather than successful zero totals.
Short retention or unknown completeness is shown as incomplete history.

Completed full-image responses count completed GET 200 image requests. Ranges
count GET 206 separately. Transferred bytes count response-body bytes written for
image GET 200/206 requests, including interrupted transfers and multipart range
framing. HTTP headers, HEAD, 304, catalog/dashboard and error-page bytes are
excluded. Retries remain separate requests. These counts
do not identify people or prove successful container imports.

Repository status is secondary and collapsed. It explains available versions,
unique retained files, retained payload size, image work and staging expiry.
Retained payload bytes do not report filesystem capacity or free space. An
opaque catalog snapshot ID appears only in collapsed technical details, labelled
as catalog state rather than a Git commit. The public page excludes requester
IP/UA, private paths, raw run/source records and work-item messages.

The responsive layout uses local CSS and a small local theme script, with a
same-origin-only script/style CSP. System mode follows the operating system's
light/dark preference; Light and Dark override it. Only that preference is
saved in local storage, and storage failure does not prevent switching themes.
Ordinary links, pagination and native disclosure controls work without
JavaScript. Keyboard focus remains visible. File/storage/transfer sizes use
1024-based IEC units with exact integer bytes in titles and JSON.

Legacy daily counters group by UTC day, public/run scope,
request kind, resolved tuple/format, method, status and response outcome. They have
a configured day window and row cap. Request paths, run IDs, IPs and User-Agents
are not aggregate dimensions. Statistics share the repository database; schema
upgrade and recovery requirements are documented in [README](README.md).

Counts describe requests and bytes written by this instance. HEAD, INDEX/listing,
206 ranges, 304 validation, errors and retries remain separate events. Retries and
overlapping ranges can repeat bytes; a full server response does not prove a
completed client download or container import. NAT can share IPs, and clients
choose User-Agent. These counters do not identify people or measure fleet totals.

## Private access log schema

The dedicated access log is JSON Lines schema 1, one event per completed or
interrupted response. Fields are `schema`, `timestamp` (UTC), `request_id`,
`repository`, `instance`, `client_ip`, `socket_peer`, `method`, `path`, `status`,
`bytes`, `duration_ms`, `scope`, optional `run_key`, `kind`, optional `tuple`,
`format` and `file_id`, `user_agent`, optional `range`/`content_range`, and
`outcome` (`complete` or `interrupted`). A response interrupted before headers
has status 0. `bytes` counts successful writes, including partial responses.
Paths exclude queries; arbitrary headers and credentials are omitted. Strings
are bounded and JSON escaped, so a User-Agent cannot inject a second log line.

The log directory must be private (0700); active and rotated files are 0600.
Set explicit maximum bytes per file and total retained file count, including the
active file. The bounded event queue never blocks a download. A full queue drops
measurements; failed log/statistics writes increase observable aggregate health
counters. A log-open failure does not prevent public serving. Statistics and raw
logs are separate from catalog integrity and file retention. Keep application
diagnostics in the process journal rather than mixing them with access events.

The HTTPS edge must overwrite the configured requester header with its socket
peer address. Trust that header only from the exact configured proxy prefixes.
The handler accepts one canonical IP, rejects chains/duplicate fields/invalid
values, and ignores forwarded headers from other peers. It records the socket
peer separately. If an inner proxy remains, preserve only a value received from
the trusted edge. Verify this chain and direct-request spoof resistance before
deployment; a generic X-Forwarded-For header is not an identity boundary.

Close the observer with a finite shutdown context after stopping HTTP handlers.
A slow filesystem can delay the background writer; a shutdown deadline must not
be replaced with an unlimited wait. Pending measurements may be lost on forced
exit. Neither statistics nor private request details are included in portable
public generation exports.
