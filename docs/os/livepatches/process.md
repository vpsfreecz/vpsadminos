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

## Repository unit

Each numbered release is one flat unit:

```text
os/livepatches/batches/<kernel-version>.<ordinal>/
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

`default.nix` separates the producer batch, qualification and documentation
reference. Only the batch enters producer identity and module bytes.
Qualification code, helpers, validators and documentation links do not. A
change confined to those inputs must not rename or rebuild the module.

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

Every fix still has one qualification manifest so catalog and coverage closure
remain exact. The manifest contains only executable oracle identity, role,
applicable platforms, timeout, expected outcome, adapter and validator. A
fix-local adapter may exercise ordinary affected-subsystem operation around
load and unload. It must not manufacture the original defect.

## Prepare a candidate

1. Select the configured kernel through the normal vpsAdminOS configuration.
   The selected package supplies the exact source, development tree,
   configuration, `Module.symvers`, `vmlinux`, compiler/toolchain and any
   built-in module inputs used by the producer. Do not introduce a parallel
   target selector.
2. Confirm that the target release page covers the exact configured kernel.
   Same-version kernel builds are not interchangeable. The runtime manager
   compares the configured boot image and extracted ELF notes with the running
   kernel before it changes livepatch state.
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

The [downstream patch-series policy](../patch-series-policy.md) applies to the
payload and repository history. Fold development repairs into their logical
owner, remove obsolete WIP/fixup history and preserve truthful provenance.
Run the repository's mandatory independent review after the intended history is
consolidated and quick checks pass.

## Dependency and rebuild decisions

Derive the current candidate from the current dependency graph. Nixpkgs or
toolchain movement can change the kernel or module realization even when the
source-level fix is unchanged.

| Change | Required response |
| --- | --- |
| Documentation, qualification profile, oracle, helper or validator only | Keep producer identity and module bytes unchanged. Re-run the affected qualification or documentation checks. |
| Payload bytes, patch order, affected-function declaration, payload revision or semantic-union lineage | This is a semantic payload change. Before publication, rebuild and qualify it as a changed candidate. After publication, use a new ordinal. |
| Livepatch release framework or kpatch builder | Derive a new current candidate and inspect the complete emitted closure. Any changed module or closure needs fresh qualification. |
| Nixpkgs, compiler, binutils, kernel package, kernel configuration, built-in module input or another target-build dependency | Derive against that exact configured kernel. Capture the new realization and run fresh exact-kernel qualification when the target, module or closure changes. |
| Released predecessor or intentionally supported frozen boot ABI | Preserve and verify its exact released bytes and recorded derivation evidence. Do not replace it with a rebuild. |

Semantically identical dependency movement is recorded relationally: capture
the candidate's source/input graph, deriver and requisites and compare the
normalized semantics. It is not permission to reuse an older module. Freeze
exact bytes only for released predecessors or an intentionally supported frozen
boot ABI.

## Capture and qualification

Capture one successful build realization, then verify every consumer against
that capture. The capture contains the ordered release set and, for each member,
the module bytes, manifest, inspection, closure, exact target, deriver and
requisites. A workflow row must rehash and validate the capture before it uses
the module. It must not independently discover or rebuild a different current
producer and call the result equivalent.

The stable maintainer entry points are:

```sh
tools/livepatch/discover.sh --plan livepatch-plan.json --matrix livepatch-matrix.json
tools/livepatch/capture.sh --plan livepatch-plan.json --output livepatch-capture.json --evidence-dir livepatch-evidence
tools/livepatch/verify.sh --plan livepatch-plan.json --capture livepatch-capture.json
tools/livepatch/verify.sh --plan livepatch-plan.json --capture livepatch-capture.json --row-id ID --result result.json
tools/livepatch/run-profile.sh --plan livepatch-plan.json --capture livepatch-capture.json --row-id ID --state-dir DIR
```

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

Run the generic lifecycle, representative busy-transition and
failure/recovery profiles on real AMD and real Intel/KVM hosts. These six rows
have no fix oracle IDs and never import or run a fix adapter. Each guest first
proves its x86_64 CPU vendor, hypervisor flag and KVM identity. The lifecycle
profile loads root to tip and reverses newest first. The busy profile keeps
independent CPU, scheduler, fork/exec, cgroup-v2 migration, loopback network,
and fsync/rename/checksum counters progressing through every normal forward and
reverse convergence, then proves bounded cleanup of its own resources. The
failure profile requires real duplicate insertion and enabled-tip removal to
fail without changing the active tip, then follows the normal rollback path.

Every successful generic row emits one structured
`VPSADMINOS_LIVEPATCH_GENERIC_RESULT` marker. The generic host validator binds
that marker to the planned row, set, profile, role, platform, members, forward
and reverse observations, plus the applicable busy or failure facts. A zero
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

Before publishing `.2`, deploy and verify list-capable readers before the
plural metadata/runtime writer. Qualify `.1` plus `.2` in both forward and
reverse directions, including out-of-order refusal, predecessor protection,
restart/idempotence and all active fix profiles. The current scalar manager supports
only native to `.1`; registration of a real `.2` remains an error until the
plural manager and reader-first compatibility work are complete.

## Publish and operate

The target page is the operator authority for eligibility, supported mixed
versions, commands, expected release levels, maximum stack depth and current
qualification status. Do not infer rollout permission from a successful build.

The generic manager provides the manual `live-patches status`,
`live-patches list`, `live-patches load` and `live-patches unload` commands.
Use `status` and `list` before changing state. The target page supplies the
release-specific order, expected output and recovery boundary for `load` and
`unload`.

The first release is manual and boot autoload remains disabled. Before each
node:

1. Confirm the node is healthy and has the exact approved boot image and notes.
2. Confirm the captured module and all structured evidence match the approved
   realization.
3. Confirm the current native or predecessor release is exactly the state
   required by the target page.
4. Quiesce or bound affected work as required by the fix and establish
   monitoring before loading.
5. Load only the next contiguous release. Wait for `enabled=1`, `transition=0`,
   `replace=0` and the expected published release before continuing.
6. Run every active fix oracle and the required health/workload checks. Preserve
   the receipt before proceeding to another node.

Mixed native, patched and native-fixed nodes may coexist only where the target
page says so. Stop on an image/notes mismatch, malformed capture, unexpected
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
