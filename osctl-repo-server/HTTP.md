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

`/usage`, `/images` and `/status` are separate server-rendered pages. `/` defaults
to Usage; old root catalog selections and `/v1/` open Images. Catalog directories
and sealed-run directories retain their image links for native clients.
`/dashboard.json` provides its aggregate data without requester fields. Dashboard
responses use no-store; repository responses require revalidation. Keep every
artifact route through the handler, including aliases, rather than adding a
static fallback that exposes files pruned from the public catalog.

## Public statistics

The dashboard uses the configured repository display name and optional purpose.
Empty display name falls back to the stable repository ID; empty purpose is
omitted. Both are escaped plain text. The serving program and project links are
in the footer; presentation configuration does not rename the repository key.
The header links to Usage, Images and Status. Only the selected page body is
rendered and read: common overview plus usage or catalog, while Status reads only
the overview. Images and Status do not query usage.

Images are grouped by distribution, architecture, vendor/variant, then version.
With JavaScript, expanding a row loads only that branch through the bounded
catalog API and keeps its ancestors visible. Collapsing it removes its children.
More appears only when another page exists. The active control retains focus and
scroll position. Usage links select statistics independently of tree expansion.
File URLs appear in each version's Files disclosure. Files and directories show
logical bytes and UTC last-modified dates. Directory metadata remains visible
when expanded; an unknown date is an em dash, and missing ancestor metadata is
labelled unavailable.

Ordinary links retain no-JavaScript server navigation. The URL records selected
ancestors and usage filters for reload/back/forward. Usage changes replace only
the usage panel from the same bounded server-rendered HTML, preserving the shared
escaping boundary. Pending requests are cancelled and older responses cannot
overwrite a newer selection. Replaced catalog cursors refresh only the affected
branch. Cross-page links use ordinary navigation. Old root usage/images/status
fragments redirect to their page when JavaScript is available.
The initial HTML does not embed the complete catalog or fetch the legacy
`/dashboard.json` response. The legacy JSON response remains complete.

Usage starts with the last seven UTC days of public image traffic. Today and
7, 30, 90, 180 and 365 day links use rolling day windows. The page shows the
exact start/end, latest measurement and retained-history coverage.
Labelled Distribution, Architecture, Vendor, Variant and Version selects have
explicit All values and Apply/Clear controls. Choices come from the current
catalog, at most 100 per active hierarchy level, with More choices links when
another page exists. Parent changes clear dependent draft choices with JavaScript;
ordinary GET submissions also work. Selected values missing from the current
page remain selectable, including retired images reached by complete tuple links
or saved URLs. Options do not enumerate historical statistics.

The applied summary describes all five filters, grouping and period for the
successfully displayed result; draft changes do not relabel it. From/To give its
UTC bounds. Ranked rows are paged. Totals, daily counters and ranked rows share an immutable
snapshot computed once per selection; later pages reuse it. Daily counters contain
at most 365 rows. Expired or evicted cursors ask the reader to restart. See
[usage query bounds](README.md) for cache limits and query deadlines.
Two daily bar graphs use that same full-selection snapshot: Transferred data
shows response-body bytes and Downloads shows completed full-image responses.
The graphs retain every UTC day (at most 365), independent of ranked pagination.
The current UTC day ends at the snapshot time. Axes start at zero; transfer uses
one IEC unit and downloads use response counts. Exact integer values are available
in SVG titles and a local keyboard/pointer day readout, with one keyboard entry
per graph. The labelled graphs and concise text equivalents work without
JavaScript; no duplicate daily table is rendered.

Days before the later retained start or retention cutoff are unmeasured. The
backend zero-fills absent daily rows and has no per-day completeness flag, so
incomplete or unknown history cannot establish measured zero: zero/missing slots
show no recorded value. Positive counters remain recorded even when the retained
start is unknown. Only complete known coverage permits measured-zero markers.
Gaps are not interpolated. Malformed or negative graph data uses the existing
unavailable response rather than fabricated success.

The four metric cards show their labels and values. Transfer caveats are in the
local native help disclosure attached to Transferred, available on hover, focus,
activation and touch with the same Escape behavior as history help. The exact
configured purpose spans the available header width without changing its text.

Unavailable measurements show an error rather than successful zero totals.
Short retention or unknown completeness adds a warning icon beside From. Its
closed disclosure explains retained start, retention and missing-record meaning
on hover, keyboard focus/activation or touch. Escape dismisses it with JavaScript;
its native disclosure remains usable without JavaScript.

Completed full-image responses count completed GET 200 image requests. Ranges
count GET 206 separately. Transferred bytes count response-body bytes written for
image GET 200/206 requests, including interrupted transfers and multipart range
framing. HTTP headers, HEAD, 304, catalog/dashboard and error-page bytes are
excluded. Retries remain separate requests. These counts
do not identify people or prove successful container imports.

The separate Status page explains available versions,
unique retained files, retained payload size, image work and staging expiry.
Retained payload bytes do not report filesystem capacity or free space. An
opaque catalog snapshot ID appears only in collapsed technical details, labelled
as catalog state rather than a Git commit. The public page excludes requester
IP/UA, private paths, raw run/source records and work-item messages.

The responsive layout uses local CSS and a small local enhancement script, with
a same-origin-only script/style/connect CSP. Three icon buttons select System,
Light and Dark, with accessible labels, pressed state and visible focus. System
follows the operating system's light/dark preference; Light and Dark override it.
Only that preference is saved in local storage, and storage failure does not
prevent switching themes.
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

## Catalog API metadata

`/dashboard/api/catalog` rows include integer `bytes` and nullable
`last_modified`; each download includes the same nullable timestamp. `bytes`
sums every descendant canonical tuple/format entry in the complete catalog
before pagination. Defaults and tags do not add entries; distinct canonical
paths sharing a file identity each contribute their listed size. These are
logical listing totals, separate from unique retained storage bytes.

A directory timestamp is the latest descendant file timestamp only when every
descendant timestamp is known. Empty directories or any unknown timestamp yield
`null`; known timestamps are RFC3339 in UTC. File values come from stored
immutable metadata. Invalid or overflowing byte sums reject the snapshot without
returning partial totals. Existing filters, limits and cursors are unchanged.

`ancestors` contains at most three selected parent rows, in root-to-parent order,
from the same complete immutable catalog generation as `rows`, independent of
cursor and limit. At the root it is `[]`. Unmatched ancestors are omitted; no
synthetic zero totals or publication timestamps stand in for missing metadata.

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
