# Kernel livepatch target-page template

Use this template for `docs/os/livepatches/<kernel-version>.md`. Keep one target
page per native kernel line and add one section per numbered release. Updating
that page must not require another MkDocs navigation entry.

The target page contains durable release facts, operator eligibility and
qualification status. Do not record current store paths, derived module names,
target IDs, profile counts, or module/evidence checksums. Those values belong in
the captured realization and release evidence.

## Source layout checklist

Each release uses this flat layout:

```text
os/livepatches/batches/<kernel-version>.<ordinal>/
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
and rollout requirements.

## Target-page skeleton

Copy the following Markdown into the target page and replace every angle-bracket
placeholder. Remove comments that do not apply; do not remove required safety
sections.

````markdown
# Linux <kernel-version> livepatch releases

This page covers livepatches built for the exact configured Linux
<kernel-version> target. Same-version kernel builds are not interchangeable.

## Eligibility

- **Eligible boot identity:** <durable description of the approved configured
  kernel; point to release evidence instead of pasting a store path or hash>
- **Native-fixed recovery coverage:** <approved reboot target when known, or
  `not yet established`; this is not a universal direct-reproducer gate>
- **Supported mixed versions:** <native, numbered releases and native-fixed
  combinations that may coexist>
- **Maximum qualified stack depth:** <tested depth for this kernel epoch>
- **Boot autoload:** disabled

Do not activate a preventive livepatch on a boot that has already hit the
target failure, has an unexplained Oops, or is otherwise unreliable. Follow the
recovery section instead.

## Release set

| State | Predecessor | Fixes | Qualification | Operator status |
| --- | --- | --- | --- | --- |
| Native `<kernel-version>` | none | none | <native evidence status> | <native eligibility or restrictions> |
| `<kernel-version>.1` | native | <fix IDs> | <status and durable evidence reference> | <blocked, qualified or retired> |
| `<kernel-version>.2` | `<kernel-version>.1` | <fix IDs> | <status and durable evidence reference> | <blocked, qualified or retired> |

Remove unused future rows. Never use a skipped ordinal. Before adding `.2`,
complete reader-first plural metadata/runtime deployment and whole-stack
qualification.

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
- **Held-frame proof:** <required by this release policy and evidence, or `not
  required`; record the availability of a safe hold point>
- **Every active dedicated fix-local operation-safety profile:**
  <status/evidence>
- **Whole-stack forward/reverse:** <status/evidence>
- **Fatal kernel-noise and workload-health gate:** <status/evidence>
- **Unsupported or blocked rows:** <reason/evidence, or `none`>

State measured transition results if available. Do not claim that an additive
module is faster or safer without a comparable measurement under the same
representative load.

### Activation

List the exact starting release, health and workload prerequisites, monitoring,
quiescence requirements, manual command, expected `enabled`, `transition`,
`replace` and published-release state, active oracle checks, and stop
conditions. Load only the next contiguous release.

### Rollback

State whether reversal is supported. Describe newest-first disable/removal,
the expected predecessor release, the predecessor oracles that must be rerun,
and the boundary where forced removal is forbidden.

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
  busy operation, activation/convergence, failure handling without fatal kernel
  noise, every active dedicated fix operation-safety profile and whole-stack
  forward/reverse behavior. Generic rows do not run fix adapters.
- A missing safe hold point is recorded without a synthetic replacement. It
  blocks the release only when the target release policy requires held-frame
  proof.
- Operator steps preserve the exact boot image/notes refusal and never use
  force.
- Rollback is newest first and retests the exposed predecessor.
- Already-hit and unexplained-Oops boots are recovery-only.
- Current producer paths, module names and checksums are absent.
