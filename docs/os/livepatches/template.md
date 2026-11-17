# Kernel livepatch target-page template

Use this template for `docs/os/livepatches/<kernel-version>.md`. Keep one target
page per native kernel line and add one section per numbered release. Updating
that page must not require another MkDocs navigation entry.

The target page contains durable release facts, operator eligibility and
qualification status. Do not record current store paths, derived module names,
target IDs, profile counts, or module/evidence checksums. Those values belong in
the captured realization and release evidence.

## Source layout checklist

Group releases by kernel version and place each batch in its ordinal directory:

```text
os/livepatches/batches/<kernel-version>/<ordinal>/
├── default.nix
├── series.nix
├── fixes/<fix-id>.nix
├── patches/<patch-id>.patch
└── qualification/
    ├── default.nix
    ├── oracles/<fix-id>.nix
    ├── helpers/<fix-id>/       # only for several helper files
    └── validators/<fix-id>/    # only for several validator files
```

Check the following before adding the target-page section:

- The public release ID is `<kernel-version>.<ordinal>`. The descriptor's
  `kernelVersion` and `release` match the directory components, which contain
  no leading zeroes; the ordinal is positive.
- `default.nix` returns separate `batch`, `qualification` and `documentation`
  values.
- `series.nix` is the only patch-order authority.
- Every fix ID matches its flat descriptor filename.
- Every descriptor records provenance, CVEs, prerequisites, affected functions,
  patch IDs and oracle IDs.
- Every series entry records its patch ID, flat patch path and all owning fix
  IDs.
- Every payload is unmodified, canonical `git format-patch` output. Its reviewed
  authority, byte comparison, SHA-256 checksum, Git blob ID, stable patch ID
  and zero-fuzz application are recorded in release evidence.
- The producer's materialized patch input is byte-identical to the repository
  file.
- A replacement repeats every payload check and leaves the module identity and
  structured manifest, inspection and closure unchanged. Otherwise it is a new
  payload candidate that needs the applicable build, review and qualification.
- Every selected fix has exactly one `qualification/oracles/<fix-id>.nix`
  manifest.
- A fix-named helper or validator directory exists only when several support
  files justify it.
- Qualification and documentation values are excluded from producer identity.

See the [canonical process](process.md) for normalization, build, qualification
and rollout requirements. Use its [fast checks before a campaign](process.md#fast-checks-before-a-campaign)
to verify changed interfaces with the existing test infrastructure. Record
development-short and release-duration results separately; qualify the entire
active set and every active fix profile for each new batch.

## Configured-kernel checklist

Follow the [configured-kernel requirements](process.md#configured-kernel-and-running-boot):

- Build from the final system's `boot.kernelPackage`, including the caller's
  Nixpkgs, kernel settings and built-in modules. Record the producer's source,
  development tree, config, toolchain, `vmlinux` and `Module.symvers` inputs.
- Compare the affected code and ABI when the configured build differs from
  the running build. Store paths and whole-image or notes hashes are not
  runtime admission checks.
- Qualify the [older-boot/newer-userspace path](process.md#verify-an-older-boot-with-newer-userspace)
  before claiming that the update preserves livepatch support. Keep this result
  distinct from qualification performed after booting a newer kernel.

## Target-page skeleton

Copy the following Markdown into the target page and replace every angle-bracket
placeholder. Remove comments that do not apply; do not remove required safety
sections.

````markdown
# Linux <kernel-version> livepatch releases

This page covers livepatches built from the final system configuration's Linux
<kernel-version> package. It records supported running builds and compatibility
qualification for deployment across kernel builds.

## Eligibility

- **Configured kernel:** <supported final kernel configuration and producer
  inputs; point to release evidence instead of pasting a store path or hash>
- **Eligible running kernels:** <base release and code/ABI compatibility scope,
  including older builds tested with the newer configuration>
- **Native-fixed recovery coverage:** <approved reboot target when known, or
  `not yet established`; this is not a universal direct-reproducer gate>
- **Supported mixed versions:** <native, numbered releases and native-fixed
  combinations that may coexist>
- **Maximum qualified stack depth:** <tested depth for this kernel epoch>
- **Boot loading:** `services.live-patches.loadOnBoot`, default `true`
- **Live deployment loading:** `services.live-patches.loadOnSwitch`, default
  `false`

Do not activate a preventive livepatch on a boot that has already hit the
target failure, has an unexplained Oops, or is otherwise unreliable. Follow the
recovery section instead.

## Release set

| State | Predecessor | Fixes | Qualification | Operator status |
| --- | --- | --- | --- | --- |
| Native `<kernel-version>` | none | none | <native evidence status> | <native eligibility or restrictions> |
| `<kernel-version>.1` | native | <fix IDs> | <status and durable evidence reference> | <blocked, qualified or retired> |
| `<kernel-version>.2` | `<kernel-version>.1` | <fix IDs> | <status and durable evidence reference> | <blocked, qualified or retired> |

Remove unused future rows. Never use a skipped ordinal. Qualify the complete
set before releasing a new batch. Deploy compatible monitor readers before
rolling out the plural writer to nodes.

<a id="release-<kernel-version-with-dashes>-<ordinal>"></a>
## Release `<kernel-version>.<ordinal>`

### Identity and provenance

- **Release:** `<kernel-version>.<ordinal>`
- **Payload revision:** <positive authored revision>
- **Predecessor:** <native or exact prior numbered release>
- **Mode:** additive, `replace=0`
- **Source commits:** <canonical repository and full commits>
- **CVEs:** <IDs, or `none assigned`>
- **Prerequisites:** <fix/patch IDs or `none`>

Do not paste the derived module name, current store path or checksum here.

### Backport selection and provenance

- **Selected source:** <canonical repository and full commit>
- **Source release and status:** <upstream, stable or downstream release and
  provenance status>
- **Prerequisites:** <required source changes, or `none`>
- **Source-review conclusion:** <what the selected change does and which
  adjacent changes are intentionally excluded>
- **Target-applicability conclusion:** <why the change applies to this exact
  target>
- **Expected emitted semantic closure:** <object, function and symbol-position
  inventory>
- **Accepted selection evidence:** <optional durable reference; keep volatile
  run IDs, paths and receipts outside this page>

Backport selection is an input review, not a livepatch qualification profile.
Do not add vulnerable or corrected reproduction, bug-specific failure injection,
or native-fixed comparison fields to the livepatch matrix.

### Fixes and emitted closure

| Fix ID | Prevention or correction | Patch IDs | Affected object/functions | Oracle IDs |
| --- | --- | --- | --- | --- |
| `<fix-id>` | <exact behavior> | `<patch-id>` | `<object>:<function>` | `<oracle-id>` |

For an overlapped function, name the exact predecessor owner and describe how
the successor implements the inherited and new semantics. List every inherited
and new oracle.

### Livepatch-safety qualification

- **Catalog and producer inspection:** <status/evidence>
- **AMD lifecycle, busy operation and failure/recovery:** <status/evidence>
- **Intel/KVM lifecycle, busy operation and failure/recovery:** <status/evidence>
- **Aging duration and status on each required platform:** <evidence class,
  configured and observed duration, status and durable evidence reference>
- **Held-frame proof:** <required by this release policy and evidence, or `not
  required`; record the availability of a safe hold point>
- **Every active dedicated fix-local operation-safety profile:**
  <status/evidence>
- **Older boot with newer userspace:** <older running build and newer final
  configuration, unchanged state with automatic loading disabled, explicit
  load/convergence/operation, reverse and cleanup status; do not substitute a
  fresh-kernel boot result>
- **Whole-stack forward/reverse:** <status/evidence>
- **Fatal kernel-noise and workload-health gate:** <status/evidence>
- **Unsupported or blocked rows:** <reason/evidence, or `none`>

State measured transition results if available. Do not claim that an additive
module is faster or safer without a comparable measurement under the same
representative load.

### Activation

Describe the host policy and any release-specific eligibility restrictions.
With `services.live-patches.enable = true`, boot loading defaults to on and
live deployment loading defaults to off. Both options are independent; link to
the [automatic-loading policy](process.md#automatic-loading) for the four
combinations. Set both to `false` when loading must remain manual. Rollout
approval applies to automatic and manual activation.

Boot and live `test`/`switch` hooks each make at most one manager attempt when
enabled. A logged failure does not abort boot/switch or trigger a retry.
Service creation or restart does not load or unload a patch. State how to
verify the resulting kernel state before returning the node to service.

List the exact starting release, health and workload prerequisites, monitoring,
quiescence requirements, manual command, expected `enabled`, `transition`,
`replace` and published-release state, active oracle checks, and stop
conditions. Use `live-patches load <ordinal>` to load this batch only after
its predecessors are applied. Explain that bare `live-patches load` loads all
batches shipped by the configuration and waits for each transition before
advancing. Keep the documented maximum depth tied to actual qualification.

### Rollback

State whether reversal is supported. Describe newest-first disable/removal,
the expected predecessor release, the predecessor oracles that must be rerun,
and the boundary where forced removal is forbidden. Use
`live-patches unload <ordinal>` for one active tip; bare `live-patches unload`
removes every loaded configured batch newest first. The manager waits for each
reverse transition and module removal before proceeding.

Disabling a loading option does not unload an active patch. Configuration
rollback does not restore live kernel state. Describe how `status` exposes
loaded modules absent from the current configuration, and require restoring a
generation that configures the loaded stack before managed removal. Include
the approved reboot alternative. Older generations retain their own activation
policy and manager capabilities.

### Recovery

Describe failover/fencing, the approved native-fixed reboot target, uncertain
operation reconciliation and post-reboot checks. Make clear that a livepatch is
preventive and is not recovery for a boot that already hit the failure.
````

## Review checklist

- The release table is contiguous from native to the selected tip.
- Every section matches one catalog unit and its documentation anchor.
- Provenance and function/patch/oracle IDs agree with the descriptors and
  `series.nix`.
- Same-function overlap has an explicit semantic-union successor.
- Backport provenance, source review, target applicability and expected emitted
  closure are separate from livepatch-safety qualification.
- Livepatch safety covers exact AMD and Intel/KVM lifecycle, representative
  busy operation, release-selected aging, activation/convergence, failure
  handling without fatal kernel noise, every active dedicated fix
  operation-safety profile and whole-stack forward/reverse behavior. Generic
  rows do not run fix adapters.
- A missing safe hold point is recorded without a synthetic replacement. It
  blocks the release only when the target release policy requires held-frame
  proof.
- The producer uses the final configuration's kernel package. Qualification
  covers loading its livepatch on the intended older running build, followed
  by operation checks and reversal without a reboot.
- Operator steps preserve module integrity, kernel compatibility and state
  checks and never use force.
- Boot and live deployment loading have independent options, with defaults
  `true` and `false`; failure handling and manual operation remain explicit.
- Rollback is newest first and retests the exposed predecessor.
- Already-hit and unexplained-Oops boots are recovery-only.
- Current producer paths, module names and checksums are absent.
