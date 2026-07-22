# Downstream patch-series policy

This policy applies permanently to vpsAdminOS integration history and to the
downstream Linux, OpenZFS, and LXC patch stacks. It applies to new work, ports,
rebases, release branches, and later maintenance.

The shipping series is a reviewable sequence of logical changes. It is not a
chronological record of every repair made while developing those changes.

## Sources of truth

Select work from live issue and pull-request state together with repository
documentation. Review Git history and source directly, then record ownership
decisions, exact refs, validation results, and remaining work in the existing
Markdown release tracker.

Release-specific exclusions, bases, and validation requirements belong in the
existing Markdown release plan or tracker. Do not turn a temporary release
decision into an implicit permanent policy.

Do not create a review harness, schema, machine ledger, JSON/TSV manifest,
registry, generator, verifier, scheduler, evidence bundle, or another parallel
state system. Normal repository build, test, lint, QEMU, and CI commands
validate the product; they do not track or prove the review itself.

## Logical patch ownership

One commit owns one coherent feature, new type of functionality, or distinct
behavior change. Fold implementation helpers, callers, tests, refinements, and
repairs into that owner when they exist to deliver the same behavior.

In particular:

- fold every caused regression fix, compatibility adjustment, cleanup,
  missing include, mode correction, test repair, and later completion into its
  logical owner;
- fold functionally equivalent, substantially overlapping, and tightly
  coupled implementation commits instead of preserving development stages;
- split mixed commits along semantic ownership boundaries;
- retain an independent upstream or baseline fix as its own patch when it
  fixes a problem not introduced by the downstream stack;
- remove duplicate, superseded, or reverted work only after lineage and tree
  evidence proves that the intended behavior and provenance remain; and
- keep separate commits only when each behavior is independently meaningful,
  reviewable, and useful as a bisect boundary.

Do not target a commit count and do not replace repair clutter with an
unreviewable mega-patch. The final history must not contain `fixup!`, `squash!`,
WIP, or later repair commits that belong to an earlier owner.

## Downstream identity

Every Linux, OpenZFS, or LXC commit that carries genuine vpsAdminOS-owned
functionality, ABI, product policy, isolation model, or intentional behavior
must begin with the exact subject prefix `[vpsAdminOS]`.

Do not add the marker merely because vpsAdminOS ships a patch. Pristine
upstream backports and independent generic fixes keep truthful upstream or
subsystem identity and provenance. Support changes folded into a product patch
share the owner's identity.

OS commits do not use the marker because this repository is already the
vpsAdminOS product boundary. They remain subject to every other ownership,
message, version, review, and validation rule.

## Versions and development history

Version the logical patch, not a Git object or publication event. An
unversioned initial published patch is its first version. Advance `vN` for a
real later source, semantic, compatibility-port, folded-content, or substantive
message revision. A pure transplant with no such change remains the same
version.

Never reuse or lower a version. Recover the highest real version from the
maintained lineage and prefer the next whole `vN`. The shipping stack contains
the current version, not successive old versions followed by a repair.

Every revised downstream-maintained patch must include a chronological
development history. Each entry explains what changed in that version; a list
of hashes, `Fixes` trailers, or "port to this release" is not sufficient.

## Commit descriptions and provenance

Every meaningful retained commit must explain:

- the problem and operational motivation;
- behavior before and after the patch;
- why vpsAdminOS needs the behavior, or why an independent patch is carried;
- the design, important invariants, constraints, and non-goals;
- accurate authorship, contributor credit, sign-offs, and provenance;
- validation performed; and
- substantive chronological development history when the patch is revised.

Preserve complete upstream messages and authorship for pristine backports.
Identify an adapted upstream source with its exact upstream commit and truthful
porting notes. Never invent provenance.

Reject truncated subjects, empty or sign-off-only bodies, vague repair
messages, temporary audit narration, and descriptions that no longer match the
folded content.

## Reconstruction and review

Before rewriting a maintained range, create an exact dated local backup ref and
work in an isolated topic worktree. Review and account for every old commit
directly in the existing Markdown release tracker. Prove a history-only
reconstruction against the old range before mixing in intentional source
changes.

Review every resulting commit and the complete tree for semantic ownership,
dependency order, bisectability, identity markers, version history, authorship,
provenance, tests, and release-specific exclusions. Use repository-native
format, lint, build, and runtime tests in proportion to the change.

Update OS component pins and source hashes only after the component heads are
final. Keep a single final pin per component rather than a trail of
intermediate repins.

Do not promote a downstream release ref until direct patch-by-patch and
final-tree review plus appropriate exact-head product validation pass.
