# Kernel livepatch release process

This page is the maintainer process for vpsAdminOS kernel livepatches. It
describes how a numbered release is authored, built, qualified, published and
retired. The page for the target kernel records the release-specific facts,
eligibility and current qualification status. Start a target page from the
[release template](template.md).

The implementation authorities are the [catalog and normalizer][catalog-lib],
the [target-bound producer][producer] and the [runtime manager][manager]. This
process does not replace their validation.

[catalog-lib]: https://github.com/vpsfreecz/vpsadminos/blob/master/os/livepatches/lib.nix
[producer]: https://github.com/vpsfreecz/vpsadminos/blob/master/os/packages/livepatch-module/default.nix
[manager]: https://github.com/vpsfreecz/vpsadminos/blob/master/os/modules/services/livepatches/default.nix

## Release model

The unmodified target kernel is the native state. Public livepatch releases for
Linux 6.12.113 are numbered `6.12.113.1`, `6.12.113.2` and so on. A numbered
release is normally a batch of related fixes, not one release per fix. Each
release builds one immutable module with `replace=0`.

Load a release set as one exact, contiguous root-to-tip stack: native, `.1`,
`.2`, through the selected tip. A later module remains additive. It transitions
only the functions it contains and leaves functions owned solely by earlier
modules active. This reduces the affected-function and build surface of each
increment compared with a growing cumulative module, but it does not prove
that activation is faster or safer. Transition latency depends on live stacks,
tasks, callbacks and system state. Make a latency claim only after measuring an
additive candidate and the relevant cumulative baseline under the same load.

Two releases may patch the same function only through a declared successor.
The successor must:

- name the exact predecessor owner;
- implement the semantic union of the inherited and new fixes;
- list all inherited and new fix and oracle IDs for the function; and
- load above the predecessor while the predecessor remains enabled.

An undeclared overlap, skipped ordinal, branch or cross-target lineage is an
error. Roll back newest first. After removing the tip, retest every oracle
owned by the newly exposed predecessor set. Never disable or remove an older
owner while its successor remains loaded.

A reboot into an approved native-fixed kernel starts a new epoch and compacts
the stack. The target page records the maximum qualified stack depth for the
current epoch. There is no universal stack-depth limit.

Module names are derived, not chosen:

```text
lp_<base-no-dots>_<ordinal>_<inputDigest12>
```

For example, the base component of a 6.12.113 release is `612113`. The digest
binds the normalized semantic, target, builder and lineage inputs. Do not use a
derived module name as the release identity.

<a id="ordered-fix-stages"></a>
### Ordered fix stages

Use consecutive additive batches when a complete fix requires ordered
transitions. For example, an earlier batch can establish lifetime handling
before a later batch enables new lookup behavior. Require full normal
convergence of each batch before loading its successor. Keep predecessors
enabled until their descendants are removed, and reverse the stages newest
first.

Give each stage truthful source provenance and fix/oracle ownership. Document
which intermediate stages provide only part of the correction and which release
first completes it. Qualify every forward and reverse boundary, including
failure and recovery while an earlier stage remains active. Splitting a fix
across batches establishes order; every stage still requires a valid old/new
transition argument and artifact qualification.

## Repository unit

Group releases by kernel version, with one subdirectory per batch ordinal:

```text
os/livepatches/batches/<kernel-version>/<ordinal>/
├── default.nix
├── series.nix
├── fixes/
│   └── <fix-id>.nix
├── patches/
│   └── <patch-id>.patch
└── qualification/
    ├── default.nix
    ├── oracles/
    │   └── <fix-id>.nix
    ├── helpers/
    │   └── <fix-id>/        # only when several helper files justify it
    └── validators/
        └── <fix-id>/        # only when several validator files justify it
```

The public release ID is `<kernel-version>.<ordinal>`. For example,
`os/livepatches/batches/6.12.113/1/` contains release `6.12.113.1`. Kernel
directories use dotted numeric versions; ordinals are positive integers.
Version components and ordinals must have no leading zeroes. Discovery requires
the descriptor's `kernelVersion` and `release` to match the path and rejects
unexpected entries.

`default.nix` separates the producer batch, qualification and documentation
reference. Only the batch enters producer identity and module bytes.
Qualification code, helpers, validators and documentation links do not. A
change confined to those inputs must not rename or rebuild the module. Put
an optional release-only flake check in `qualification/check.nix`. The function
receives `{ pkgs, plan, ciTools }` and returns the derivation for
`livepatch-qualification-<release>` (with dots replaced by underscores). The plan
covers the kernel's stack through that ordinal. Keep reusable framework checks
outside the release directory.

`series.nix` is the sole authored patch-order authority. Patch filenames and
directory order never determine application order. The catalog discovery in
[`batches/default.nix`][catalog] imports numbered directories deterministically;
there is no handwritten release registry.

[catalog]: https://github.com/vpsfreecz/vpsadminos/blob/master/os/livepatches/batches/default.nix

Use stable fix and patch IDs. A flat `fixes/<fix-id>.nix` descriptor owns:

- the fix ID and provenance status;
- the canonical source repository and full commit;
- applicable CVEs;
- prerequisites;
- affected object/function pairs;
- its unordered set of patch IDs; and
- its oracle IDs.

`series.nix` maps each patch ID to one flat patch file and all owning fix IDs.
Normalization checks the descriptor-to-series relation in both directions,
requires every patch file exactly once and requires one oracle manifest for
every selected fix. Shared prerequisite patches name every affected fix. A
single helper or validator stays flat in its manifest; add a fix-named support
directory only when several files need grouping.

Payload files must be unmodified, canonical `git format-patch` output. The Git
whitespace attribute applies only to patch files in numbered batch `patches/`
directories, where format-patch context bytes would otherwise look like source
whitespace errors. It does not relax whitespace checks for ordinary source or
for patch files elsewhere in the repository.

Before accepting a payload, compare it byte for byte with the reviewed
authority. Record and verify its SHA-256 checksum, Git blob ID and stable patch
ID, then apply it to the exact target source with zero fuzz. Also require the
producer's materialized patch input to match the repository file exactly.

Replacing a reviewed payload requires all of those checks again. The resulting
module identity and structured manifest, inspection and closure must remain
unchanged. If any check or identity changes, treat the replacement as a new
payload candidate and repeat the applicable build, review and qualification.
Whitespace normalization is not an editorial exception for payload files.

After publication, do not change a release's fixes, patch bytes, order,
framework or lineage. Publish the change as the next ordinal. Correct prose or
qualification without changing the producer batch.

### Retiring a kernel

When a kernel leaves the catalog, remove its entire numbered stack under
`os/livepatches/batches/<kernel-version>/`, its page at
`docs/os/livepatches/<kernel-version>.md`, and its `Linux <kernel-version>`
entry under **Kernel livepatches** in `mkdocs.yml`. Keep the process, template,
shared tests and framework. Packages, checks and qualification rows follow the
remaining registrations; an empty numbered catalog is valid. This removes
options from future configurations, not live patches from running machines.
Revert the whole retention change to restore a retired kernel and its files.

A deployable legacy or eBPF range payload owns its record and source in
`os/livepatches/legacy/<name>/` or `os/livepatches/ebpf/owned/<name>/`,
respectively. Keep private helpers and fixtures there, and leave independent
examples outside those roots. Maintenance uses the same version predicates as
deployment: keep a payload while another supported kernel still matches, and
remove it with its last matching kernel. It does not sweep disabled examples,
open-ended eBPF programs or payloads that already had no targets. See the
[kernel update process](../kernel-updates.md) for catalog and package data.

## Authored and derived identity

Reviewers must be able to tell which values a maintainer chose and which values
the build derived.

Authored identity includes the release and stable fix/patch/oracle IDs,
provenance commits and status, CVEs, prerequisites, affected functions, ordered
series, expected closure, predecessor declarations and payload revision.

Derived identity includes the normalized input digest, module name, patch and
module hashes, exact configured-kernel target, store paths, deriver,
requisites, inspection and closure evidence. Generate these values from the
current candidate. Do not paste them into descriptors or maintain current
producer paths, module names, target IDs, profile counts, or module/evidence
checksums as source goldens.

The producer emits the module together with its normalized manifest,
structured inspection, closure evidence, generated release header and raw
build evidence. Treat `livepatch-evidence/build.log` as a per-realization audit
record. Its raw bytes are not cross-run identity and must not be compared with
an earlier tracked hash.

## Backport selection and livepatch safety

When the task is to discover and select security fixes from a stable release
range, first use the [security backport selection guide](security-backports.md)
and obtain approval for its exact fix groups. Use this process to create and
qualify a batch from the approved fixes. An already selected exact fix enters
this process directly.

Every authored batch records its addressed issues on the existing target page
using the [target-page template](template.md). The coverage index summarizes
source coverage and the recorded qualification and operator status, with the
linked release sections and fix descriptors as authorities. Per-node activation
requires separate runtime evidence. Link the first complete, effective
correcting release. An additive successor does not replace that first release,
and an ineffective earlier attempt does not qualify as the correction.

Source provenance and newer-kernel evidence select the backport. Record the
source repository and full commit, prerequisites, affected functions, source
review, target applicability and expected emitted closure. This input review is
not a livepatch qualification profile.

Livepatch qualification tests the exact target-bound artifact and its livepatch
mechanics. It covers artifact, target and closure admission, platform admission,
safe load and convergence, representative busy progress, truthful failure and
recovery behavior, supported rollback, and fatal-noise refusal. It does not add
vulnerable or corrected bug reproduction, bug-specific failure injection, or a
native-fixed comparison. A separate kernel-fix investigation may provide
selection evidence, but it does not silently become a livepatch release gate.

vpsAdminOS does not control the workloads users run in containers, including
KVM VMs. Livepatch qualification must demonstrate clean forward and supported
reverse transitions, continued ordinary workload progress, and system stability
while those workloads keep running. Normal livepatching must not depend on
stopping, resetting, restarting or recreating user workloads, denying their
device access, or proving that no earlier bad state exists.

A preventive livepatch protects future execution; it does not repair damage
from earlier failures. Keep known failures under the existing recovery
procedure. If source or artifact analysis shows that a correction cannot
transition safely without controlling user-owned workloads, treat it as
unsupported for livepatching under that operating contract.

Every fix still has one qualification manifest so catalog and coverage closure
remain exact. The manifest contains only executable oracle identity, role,
applicable platforms, timeout, expected outcome, adapter and validator. A
fix-local adapter may exercise ordinary affected-subsystem operation around
load and unload. It must not manufacture the original defect.

<a id="preserve-a-supported-boot-target"></a>
## Configured kernel and running boot

The final system configuration selects `config.boot.kernelPackage`. The
livepatch producer uses that package's source, development output, kernel
configuration, `vmlinux`, `Module.symvers`, compiler and built-in module inputs.
This applies to vpsAdminOS alone and to configurations that supply their own
Nixpkgs or kernel settings. The build obtains these inputs through Nix;
operators do not supply development artifacts from running nodes.

A running kernel can remain in use while the system switches to a newer
configuration. Build the livepatch against the kernel selected by that new
configuration and qualify it on the older running build. Store paths, whole
kernel-image bytes and ELF notes can change without changing the code or ABI
needed by the livepatch. The manager does not compare those values for
admission.

Compatibility still depends on the patched code and its dependencies. The
kernel enforces module architecture/release checks, configured symbol-version
checks, symbol and relocation resolution, and livepatch loading and
transitions. These checks do not establish semantic compatibility by
themselves. Review the affected code and ABI, then verify load, operation and
reversal on the intended older boot. Never force a module load or transition
to bypass a refusal. Follow the
[older-boot qualification procedure](#verify-an-older-boot-with-newer-userspace).

Each generation carries modules derived from its configured kernel. A changed
build can produce a different module identity for the same authored release.
Retain a generation that can manage any previously loaded module. A newer
generation reports and refuses an unknown module without adopting or unloading
it; follow the [configuration rollback procedure](#status-and-configuration-rollback).
Numbered release links continue to use the actual booted generation's module
tree.

## Prepare a candidate

1. Select the supported base kernel through the final vpsAdminOS configuration.
   Its `boot.kernelPackage` supplies the producer inputs described above.
   Include the caller's Nixpkgs, kernel settings and built-in module choices
   when evaluating the candidate.
2. Confirm that the target release page covers the selected kernel and intended
   running builds. For an older boot with a newer configuration, review the
   affected code/ABI and include that upgrade path in qualification. Matching
   version strings alone do not prove compatibility.
3. Record authoritative provenance, prerequisites and affected functions in
   each fix descriptor. Review the complete source change and its transitive
   emitted-function closure; do not infer the livepatch closure from the source
   function named in a commit message.
4. Put every payload in `patches/` and declare the one application order in
   `series.nix`. Check descriptor/series ownership and patch IDs in both
   directions.
5. Add one fix-local qualification manifest per fix. Its executable profile
   must exercise ordinary real-subsystem operation and the safety boundaries
   that apply to the release. Keep backport-selection evidence on the target
   page or in reviewed release evidence, not in the executable manifest.
6. Normalize and build the release against the current configured target. The
   producer must use non-replace mode and must produce the expected target-bound
   module and structured evidence.
7. Compare the manifest, inspection and closure. Review every emitted
   replacement, symbol position, livepatch relocation, import, callback,
   changed object and generated release-level function. Missing, extra or
   ambiguous entries fail the candidate.
8. Before batch readiness, compare the target page's coverage index and release
   section with the final fix descriptors and ordered payload ownership. They
   must identify the same immutable fix, source and payload mapping. An
   explicitly verified later CVE association may enrich a published page while
   its original producer CVE metadata remains unchanged.

The [downstream patch-series policy](../patch-series-policy.md) applies to the
payload and repository history. Fold development repairs into their logical
owner, remove obsolete WIP/fixup history and preserve truthful provenance.
Run the repository's mandatory independent review after the intended history is
consolidated and quick checks pass.

## Dependency and rebuild decisions

Derive the candidate from the final configuration after dependency changes.
Compare its producer inputs and emitted artifact with the accepted candidate.
When the configured kernel build changes, include the older running build in
compatibility qualification before deploying the livepatch to it.

| Change | Required response |
| --- | --- |
| Documentation, qualification profile, oracle, helper or validator only | Keep producer identity and module bytes unchanged. Re-run the affected qualification or documentation checks. |
| Payload bytes, patch order, affected-function declaration, payload revision or semantic-union lineage | This is a semantic payload change. Before publication, rebuild and qualify it as a changed candidate. After publication, use a new ordinal. |
| Livepatch release framework or kpatch builder | Derive a new current candidate and inspect the complete emitted closure. Any changed module or closure needs fresh qualification. |
| Nixpkgs, compiler, binutils, kernel package, kernel configuration, built-in module input or another target-build dependency | Evaluate the final configured producer. If its inputs or artifact change, capture and qualify the new realization, including the intended older-boot/newer-configuration path. |
| Module already loaded from an earlier generation | Retain that generation for managed removal. A new generation must not adopt a different module identity. |

Record the candidate's source/input graph, deriver and requisites and compare
the normalized semantics. Reuse artifact checks only for an unchanged producer
and realization. Successful loading on another compatible kernel does not
change the module's captured build identity or transfer another artifact's
qualification results.

## Capture and qualification

Capture one successful build realization, then verify every consumer against
that capture. The capture contains the ordered release set and, for each member,
the module bytes, manifest, inspection, closure, exact target, deriver and
requisites. A workflow row must rehash and validate the capture before it uses
the module. It must not independently discover or rebuild a different current
producer and call the result equivalent.

The capture artifact carries identity and verification evidence. CI transfers
Nix store objects separately. After local verification, the capture job checks
the producer count and complete recursive requisite set against the capture,
copies those exact closures to the signed vpsAdminOS binary cache, and retains
each producer in the branch's `-livepatch` profile generations. Before other
jobs can use the capture, it verifies public availability and signatures for
the whole closure and compares each producer's NAR contents, hash, size,
references and deriver with the local object.

Consumer jobs realise the exact captured producer paths with fallback disabled,
then verify the module and evidence. Cache availability does not permit an
equivalent rebuild, a different producer or weaker capture checks.

The stable maintainer entry points are:

```sh
tools/livepatch/discover.sh --plan livepatch-plan.json --matrix livepatch-matrix.json
tools/livepatch/capture.sh --plan livepatch-plan.json --output livepatch-capture.json --evidence-dir livepatch-evidence
tools/livepatch/verify.sh --plan livepatch-plan.json --capture livepatch-capture.json
tools/livepatch/verify.sh --plan livepatch-plan.json --capture livepatch-capture.json --row-id ID --result result.json
tools/livepatch/run-profile.sh --plan livepatch-plan.json --capture livepatch-capture.json --row-id ID --state-dir DIR
```

These commands use the canonical layout: `livepatch-capture.json` and the
`livepatch-evidence` directory are siblings. Direct verification and profile
execution check only that directory; they do not search for another evidence
location. If the evidence directory has another name or location, pass its
exact path with `--evidence-dir` to both `verify.sh` and `run-profile.sh`.
When relocating canonical evidence, move the capture file and evidence
directory together under their canonical names or use the explicit option.

Use `kernel/livepatch-batch@<row-id>`, `kernel/livepatch-set@<row-id>` and
`kernel/livepatch-fix@<row-id>` as the generic test selectors. The versioned
plan, capture and result contracts are public maintainer interfaces. Flake
evaluation expressions, workflow job/output names, temporary artifact paths
and internal JSON queries are implementation details.

Qualification covers these layers:

1. Static catalog checks: schema, stable IDs, provenance, patch ordering,
   function lineage, overlap declarations and oracle closure.
2. Producer checks: exact configured target, `replace=0`, module identity,
   vermagic/signature, functions, sympos, relocations, imports, callbacks,
   changed objects and structured closure agreement.
3. Generic lifecycle: admission refusals, load, convergence, idempotence,
   partial/timeout truth, module-tree ownership and supported reversal.
4. Every active fix-local safety, operation or behavioral profile, including
   predecessor profiles exposed at each rollback level.
5. Whole-stack loading root-to-tip and reversal tip-to-root.

### Regression tests on the livepatch target

By default, normal CI builds the latest stable configuration and runs the
complete requested ordinary test suite. Each direct-boot vpsAdminOS test
machine that selects modules for automatic loading checks its livepatch state
after the production manager runs. The complete configured stack must be
present, active and converged, and `uname -r` must report the configured tip.
The check creates a fresh `/run` marker only after it passes. On failure, it
records the reason and forces the no-reboot test VM to terminate before runit
can start a test shell. Every real reboot repeats the check. Configurations
without selected modules, configurations with automatic loading disabled, and
intentional livepatch-state fixtures keep their existing behavior.

The standalone Livepatch qualification workflow calls `livepatch.yml` to
discover and capture the selected releases. It evaluates one canonical plan,
then captures and verifies each selected producer once. On a push, changes
below `os/livepatches/batches/<kernel>/<ordinal>/` select the latest complete
set for each affected kernel, including every contiguous predecessor. Other
relevant livepatch changes run the full dedicated qualification campaign
without selecting an extra ordinary-test target. A manual dispatch may select
exact kernel versions; an empty selection runs the full dedicated campaign
without an affected-target ordinary row. An inaccessible comparison range
fails the workflow.

After capture, the workflow compares each affected set with the normal CI
generation from the same source revision. Reuse requires matching source and
lock identities, automatic-load policy, target ID, ordered releases, producer
and module store paths, and module names. On a push, an exact match records
that normal CI covers that ordinary workload row. Any missing or unequal value
runs the serial affected-target row instead. A manual exact-target dispatch
always runs its ordinary row. This comparison selects coverage; it does not
establish that normal CI has passed.

An affected-target row downloads the existing plan and capture, verifies them
again after transfer, and runs the eligible ordinary `ci` scripts with the
complete captured stack. Its inventory accounts for every ordinary `ci`
script as eligible or excluded and records each exclusion reason. Before a
test shell becomes ready, the boot gate checks the native target, captured
module bytes, full manager inventory, livepatch state and tip release. Every
reboot repeats the gate. Tests use the captured modules directly.

Ordinary workload regression and dedicated livepatch qualification must both
pass at the final source revision. Dedicated qualification covers native and
intermediate stages, transitions, failure recovery, rollback and fix-oracle
evidence. Normal CI or the affected-target row covers ordinary workloads.
These results do not authorize integration, deployment, production activation
or rollout.

### Fast checks before a campaign

A new batch normally adds its descriptors, canonical patches, ordered series,
oracle declarations and target-page facts. Reuse the generic AMD and Intel/KVM
lifecycle, busy, aging and failure/recovery profiles. Add a fix-local adapter
only when the affected subsystem needs ordinary operation checks that the
existing profiles do not provide. Keep the shared producer, workflow and
result validators as the common implementation for every release.

Check changed interfaces in their existing owners before starting a campaign:

| Changed boundary | Existing check owner |
| --- | --- |
| Catalog, target, lineage or producer inputs | `os/packages/livepatch-module/tests/eval.nix`, followed by exact configured-target artifact inspection |
| Manager CLI, state, ordering or activation policy | Generated-manager unit in `os/modules/services/livepatches/tests/default.nix`; production-manager VM after review |
| Plan, topology, locked tools, capture/verification, profile handoff or result validation | `checks.x86_64-linux.livepatch-qualification` and the applicable batch's named check, if present |
| TestRunner fork/redirection or output ordering | `test-runner/spec/test_runner/executor_spec.rb` |

The focused qualification check exercises the actual profile command handoff,
separate controller and semantic logs, result ownership and count-closure
refusals. It includes the generated-manager unit and private VM render, but
runs no VM and excludes TestRunner. Keep the large-output and stream-ordering
regression with the executor; do not copy it into another fixture or rebuild
the runner for an unrelated release change.

Inspect the dry dependency graph before realizing a focused check. Unexpected
kernel, kpatch or livepatch producer builds stop that check for diagnosis.
Build and capture the intended target-bound module once, then verify every
consumer against that capture. Reuse passing checks only when their relevant
inputs are unchanged; retain exact derivation and input evidence for reused
Nix results.

Commit the intended source, tests and documentation, pass quick checks and
complete independent review before long integration tests or campaigns.
Diagnose a failure at its first failing interface and check the correction
there before repeating the campaign. Retain the failed attempt and its cause;
do not relax result validation to accept it.

Every later batch qualifies the whole active set, including predecessor
profiles exposed during newest-first removal. New payload, target, builder,
lineage or emitted closure requires fresh artifact inspection and full
qualification. Evidence for native to `.1` alone does not establish production
multi-batch manager behavior. Preserve earlier receipts at their original
source revision; path or harness changes need their affected checks and new
receipts even when the module identity is unchanged.

### Verify an older boot with newer userspace

Qualification must cover the upgrade path used by running nodes. Boot the
older kernel build, then switch to the newer userspace and final configuration
with `loadOnSwitch=false`. The new generation selects its own kernel package
and the livepatch built from it. Verify that the switch leaves livepatch state
unchanged and that release links still use the booted generation's module tree.
Explicitly load the configured set, wait for convergence, run the applicable
operation and health checks, then reverse the set and verify module removal and
native state.

Retain refusal coverage for wrong native releases, invalid module artifacts,
unknown modules left by another generation, and kernel loading failures.
A successful fresh boot into the newer configured kernel does not cover this
upgrade path. Record which older boot and newer configuration were tested;
do not infer that result from matching versions or a successful build.

### Develop aging and delay tests

For a new release or changed aging, soak or artificial-delay test, run the
complete planned matrix with the development aging class first. The short run
must complete setup and admission, workload progress, forward and reverse
transitions, module removal, cleanup, health checks and count closure before
the duration is increased. Fix harness failures with focused checks before
attempting another campaign.

Then select the release aging class, run the affected quick checks and review
the final committed selection. Run a fresh complete campaign on that exact
head, with serial rows, fail-fast cancellation and accepted count closure.
Applicable final-head CI must also pass before merge consideration. Activation
and rollout approval remain separate from qualification.

Choose a bounded final duration that exercises the intended condition. Record
the configured and observed durations with the results, and distinguish
development evidence from final qualification. A short run establishes no
longer-duration coverage. Keep real state checks and their failure deadlines
intact: a job timeout limits a failure; it does not provide an aging dwell.

### Required profiles

Run the generic lifecycle, representative busy-transition, aged-transition and
failure/recovery profiles on real AMD and real Intel/KVM hosts. These eight rows
have no fix oracle IDs and never import or run a fix adapter. Each guest first
proves its x86_64 CPU vendor, hypervisor flag and KVM identity. The lifecycle
profile loads root to tip and reverses newest first. The busy profile keeps
independent CPU, scheduler, fork/exec, cgroup-v2 migration, loopback network,
and fsync/rename/checksum counters progressing through every normal forward and
reverse convergence, then proves bounded cleanup of its own resources. The aged
profile checks the same workload during the release-selected pre-transition
dwell and records its configured and observed duration before normal forward
and reverse convergence. The failure profile requires real duplicate insertion
and enabled-tip removal to fail without changing the active tip, then follows
the normal rollback path.

Every successful generic row emits one structured
`VPSADMINOS_LIVEPATCH_GENERIC_RESULT` marker. The generic host validator binds
that marker to the planned row, set, profile, role, platform, members, forward
and reverse observations, plus the applicable busy, aging or failure facts. A zero
test-runner status without this semantic result is not accepted.

Dedicated fix-oracle rows run the declared ordinary operation-safety adapters.
The planner requires exactly one dedicated row for every active oracle and
applicable platform. The complete campaign therefore covers generic livepatch
mechanics and every active fix oracle without mixing the two code paths.

Add held-frame proof when the target release policy requires it and a reviewed
safe hold point exists. Record a missing safe hold point and do not replace it
with sleeps, repeated attempts, synthetic calls, probes that manufacture the
state, or memory manipulation. The absence of a safe hold point does not by
itself block normal-convergence safety qualification unless the release policy
explicitly makes held-frame proof an acceptance gate. Truthful synthetic
partial and timeout coverage may remain in manager unit tests; it is not a
substitute for a release-specific natural hold.

CI runs at most one qualification row at a time and requests fail-fast
cancellation after the first failure. GitHub Actions does not guarantee matrix
include order or transactional cancellation. Acceptance is therefore based on
a complete, count-closed set of successful receipts, not on row start order or
on a claim that no sibling could start while cancellation propagated.

Before deploying plural monitor metadata to nodes, deploy and verify readers
that accept the schema-2 module list and the legacy scalar format. Test the
complete release set in both directions, including out-of-order refusal,
predecessor protection, restart behavior, idempotence and every active fix
profile. Qualification
of native to `.1` does not qualify `.2` or any deeper stack.

## Publish and operate

The target page is the operator authority for eligibility, supported mixed
versions, commands, expected release levels, maximum stack depth and current
qualification status. Do not infer rollout permission from a successful build.

### Manual commands

Each numbered batch is one module. The manager selects batches from the current
system configuration for its exact configured kernel. `N` is a positive decimal
batch ordinal such as `1`, `2` or `3`; do not pass a kernel version, full release
ID or module name. Leading zeroes and extra arguments are rejected. Inspect
`status` before changing state and follow the target page's workload and
recovery requirements.

| Command | Behavior |
| --- | --- |
| `live-patches load` | Load the configured batches in ascending order, skipping the already applied and verified prefix. |
| `live-patches load N` | Load batch N only when every predecessor is applied; revalidate an already applied N without inserting it again. |
| `live-patches unload` | Remove all loaded configured batches, newest first. |
| `live-patches unload N` | Remove N only when it is the active tip or a recognized partial tip awaiting removal. An already completed removal succeeds only if the remaining stack is exactly the prefix through N-1. |
| `live-patches status` | Report configured and observed livepatch modules and their states. |
| `live-patches list` | Show the same inventory as `status`. |

Each mutation holds one global lock. Loading waits for the kernel transition to
complete and verifies the exact module, `enabled=1`, `transition=0`, `replace=0`
and the expected published release before advancing to the next batch. Unloading
waits for reverse convergence and the predecessor release, then removes the
module before proceeding to its predecessor. A successful insertion or disable
request alone is not a completed operation.

A failed step stops the command. Earlier successful steps remain in effect,
and partial or disabled-but-present state remains visible. The manager does
not undo earlier steps, force a transition or force module removal. Inspect
`status` and follow the target page's recovery procedure before continuing.
Unknown modules, gaps, wrong identities and unsupported partial states prevent
mutation.

### Status and configuration rollback

Status combines all configured batches, registered kernel livepatch entries,
and existing manager-owned module records whose exact names are still present
in `/sys/module`. It shows batches that are configured but not loaded, active
or transitioning modules, and modules that are present but no longer configured.
A module loaded by the manager remains visible after reverse convergence until
removal, even if its `/sys/kernel/livepatch` entry has disappeared. Status does
not take the mutation lock, so it can report a transition while a load or unload
command waits.

Each row contains `ordinal`, `release`, `module`, `configured`, `present`,
`enabled`, `transition`, `replace` and `state`. Configured batches retain their
release and ordinal. Runtime modules outside the configuration report those
fields as `unavailable`; an exact module name does not establish their release.
States distinguish `configured-not-loaded`, `active`, `transitioning`,
`partial/inconsistent`, `disabled-present`, `cleanup-pending`,
`loaded-not-configured` and `metadata-unavailable`. Missing metadata and
inconsistent state remain visible. The manager does not infer a release or
ownership from a module-name prefix, and it does not classify arbitrary
`/sys/module` entries as livepatches. A collection error produces an explicit error and a nonzero exit;
a reported inconsistency is not itself permission to mutate the module.

Rolling back the system configuration does not unload modules already in the
kernel. A configuration that knows only batch 1 can therefore encounter a loaded
batch 2. The plural manager reports it as loaded but not configured and refuses
mutation. Restore a generation that configures the complete loaded stack before
managed removal, or follow the target page's approved reboot procedure. This
also applies when the unknown batch has completed reverse convergence but its
module remains present.

Previously built scalar-manager generations retain their original behavior and
cannot manage a plural stack. Remove newer batches with the plural manager
before switching to such a generation, or reboot into an approved native state.

### Automatic loading

When `services.live-patches.enable` is true, two independent options control
automatic loading of the configured livepatch set:

```nix
services.live-patches.loadOnBoot = true;
services.live-patches.loadOnSwitch = false;
```

These are the defaults. They apply to numbered releases and legacy opt-in
modules. Loading policy belongs to the host configuration and does not change
the module's identity or bytes.

| `loadOnBoot` | `loadOnSwitch` | At boot | During live activation |
| --- | --- | --- | --- |
| `false` | `false` | No automatic load | No automatic load |
| `true` | `false` | One load attempt | No automatic load |
| `false` | `true` | No automatic load | One load attempt |
| `true` | `true` | One load attempt | One load attempt |

Boot loading runs after the booted generation is recorded and before runit
starts. Live loading runs during `switch-to-configuration test` or `switch`,
including activation of the same generation or a switch back to the booted
generation. The `boot` action only updates the bootloader; `dry-activate` does
not load patches. Creating or restarting the `live-patches` service does not
load or unload a patch.

Each enabled hook calls its generation's bare `live-patches load` once. The
manager verifies the active prefix and loads the remaining configured batches
in order. A failed attempt is logged, does not abort boot or switch, and is not
retried automatically. Every batch retains its target, integrity, state and
convergence checks. Check `live-patches status` and monitoring after activation.
Successful system activation or a running service does not establish that the
patch is applied.

With the defaults, deploying to a running node does not load the patch; booting
that generation does. Before booting a generation containing a release, obtain
rollout approval and check its eligibility requirements. Set both options to
`false` to keep loading manual. Explicit manager commands remain available
under every policy combination. Qualification guests select both options as
`false` so tests control insertion and removal themselves.

Disabling either option never unloads an active patch. A configuration rollback
does not restore the kernel's earlier livepatch state; follow the release's
explicit unload or reboot procedure. Previously built generations retain their
own activation behavior, so check that policy before switching to an older
generation.

### Rollout checks

Before loading each node:

1. Confirm the node is healthy and its running base kernel is covered by the
   release's compatibility qualification.
2. Confirm the captured module and all structured evidence match the approved
   realization.
3. Confirm the current native or predecessor release is exactly the state
   required by the target page.
4. Establish monitoring and keep user-owned workloads running. Quiesce or bound
   only operator-owned work when the release requires it; this must not
   substitute for proving safe transitions with user-owned workloads.
5. Load only the next contiguous release. Wait for `enabled=1`, `transition=0`,
   `replace=0` and the expected published release before continuing.
6. Run every active fix oracle and the required health/workload checks. Preserve
   the receipt before proceeding to another node.

Mixed native, patched and native-fixed nodes may coexist only where the target
page says so. Stop on a kernel module rejection, malformed capture, unexpected
livepatch state, transition timeout, failed oracle, monitoring gap, unexplained
Oops or workload regression. Never force a transition, unload a subsystem to
make it converge or toggle the patch repeatedly.

A boot that has already hit the target failure, an unexplained Oops or an
unreliable state is not eligible for preventive activation. Fail over or fence
as the service procedure requires, reboot into approved native-fixed code and
reconcile uncertain operations. Loading the livepatch is not recovery.

Rollback is newest first. Disable and remove only the tip when its target page
declares reversal supported. Wait for reverse convergence and the predecessor's
published release, then rerun every oracle that the exposed stack still owns.
A non-reversible release stops at its documented recovery boundary; recover by
the target page's reboot/failover procedure instead of forcing removal.
