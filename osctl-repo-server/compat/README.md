# Native compatibility checks

These tiny fixtures come from the existing Ruby repository writer and garbage
collector, independently of the Go service. Payloads are identifying text, not
bootable images or ZFS streams. The checks exercise repository transport and
metadata compatibility without building or downloading container images.

`generate_native.rb` invokes the real native `osctl-repo local` CLI and executes
`os/modules/services/osctl/image-repository/gc.rb`. Its only GC source substitution
is the `@osctlRepo@/bin/osctl-repo` command path normally substituted by Nix. It
does not reimplement GC selection. Fixtures retain original INDEX JSON bytes,
actual alias symlinks, payload bytes/digests/sizes, ordered input operations and
the exact source revision and SHA-256 of relevant native sources.

Scenarios cover native lexical tuple ordering, configured tag takeover (Debian's
shared `oldstable`), defaults, different vendors/architectures/variants, stream-only
images, configured Ruby regex rules, first matching rule, keep-four retention,
unmatched fixed releases, named subsets and mixed success/failure. A failed build
means no native `add`; GC still runs over the whole catalog. The mixed scenario
distinguishes five old matches pruned to four from four old matches retained when
their replacement fails. The GC scenario appends an overlapping keep-zero rule
after the real configured rules to prove first-match precedence.

Run the fast fixture integrity and provenance checks from the repository root:

```sh
python3 osctl-repo-server/compat/check_fixtures.py
```

To regenerate, enter the repository's Nix Ruby environment and supply the absolute
path to the native CLI with its normal dependency closure. Source Ruby libraries
must take precedence over installed versions. The native libosctl extension needs
the matching vpsAdminOS Ruby build; an arbitrary system Ruby extension is not a
compatible substitute. No dependency or production-code stubs are used here.

```sh
export RUBYLIB="$PWD/osctl-repo/lib:$PWD/libosctl/lib${RUBYLIB:+:$RUBYLIB}"
ruby osctl-repo-server/compat/generate_native.rb catalog /absolute/path/to/osctl-repo
ruby osctl-repo-server/compat/generate_native.rb gc /absolute/path/to/osctl-repo
ruby osctl-repo-server/compat/generate_native.rb subset /absolute/path/to/osctl-repo
ruby osctl-repo-server/compat/generate_native.rb mixed_failure /absolute/path/to/osctl-repo
```

Append `--check` to compare fresh native output with the committed fixture without
rewriting it. Source hashes must match; unrelated Git commits may advance HEAD.
Each case is independent. A full regeneration batch may take over a minute and
belongs under the normal verification monitor. Keep successful native-oracle
evidence with the tested revision. Do not silently regenerate expectations to
accept an incompatible Go result.

Black-box service checks use a disposable, separately launched service and its
real CLI/HTTP interface. Register temporary listeners through `dev-session service
run` in this workspace. The compatibility harness must not start an independent
HTTP implementation or connect to the production repository. No large artifacts,
VMs or privileged operations are required.

`service_check.py` requires an empty disposable repository. It uploads the tiny
native baseline through the real control CLI, completes items in reverse order,
and compares HTTP output with the independent native oracle. It then exercises
native direct and forced-check cached clients, stable sealed-run IMS/304, GET/HEAD
length and framing, canonical and combined default/tag paths, missing formats,
full unchanged/new run views, public GC with retained run bytes, independent good
publication after a selected failure, and same-tuple replacement through an
already populated native cache. A failed rebuild of an existing tuple must not
resolve to its pinned public baseline. Public IMS may conservatively return 200;
replacement must return new bytes even with the previous Last-Modified value.

The service must be registered and launched separately with its actual listener,
repository and role-socket options. This harness creates no listener, uses no
production defaults, accepts only explicit loopback HTTP URLs, and checks the
repository is empty before mutating it. It requires Python's standard library
and the actual native CLI. For one scenario:

```sh
python3 osctl-repo-server/compat/service_check.py \
  --url http://127.0.0.1:PORT \
  --cli /absolute/path/to/osctl-repo-server \
  --native-cli /absolute/path/to/osctl-repo \
  --producer /disposable/producer.sock \
  --publisher /disposable/publisher.sock \
  --repository vpsadminos --scenario catalog
```

Repeat with a fresh disposable repository/service root for `gc`, `subset` and
`mixed_failure`. Supply the same source-first `RUBYLIB` as for generation. The
harness intentionally uses `force-check` for cached clients so HTTP failures
cannot pass by returning cached bytes. It checks JSON object semantics and the
native ordering of image/tag arrays, without requiring object-key or whitespace
identity from the Go encoder. Exact native INDEX bytes remain in the fixtures.
