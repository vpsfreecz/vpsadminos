# Selecting security fixes for livepatch backports

Use this guide when a maintainer has to discover and select kernel security
fixes from a stable release range before creating a vpsAdminOS livepatch
batch. It produces a source-grounded selection record and an approved set of
fix groups. After approval, the selected fixes enter the
[kernel livepatch release process](process.md).

This preparation is optional. When the request already names an exact fix,
use the generic release process directly and follow its provenance,
applicability and safety requirements. This guide does not create payloads,
build a module, qualify a release or authorize rollout.

## Scope and authorities

Range-based livepatch selection covers vulnerabilities, including security
fixes without an assigned CVE. Ordinary correctness bugs are outside this
selection unless their fixes are necessary prerequisites of a selected
vulnerability correction. Record each such dependency in the exact ordered fix
group and apply the same source-approval and faithfulness requirements.

Use the source-enumeration, member-relevance, exposure and uncertainty
principles from the security-advisories
[kernel CVE selection policy][cve-selection]. Record the exact policy revision
used for each selection run. The prior-advisory, dossier, vpsAdmin draft and
publication gates in that repository belong to the advisory workflow; they do
not gate livepatch research or creation.

The livepatch selection must remain usable without a security-advisories
checkout, advisory dossier, vpsAdmin API access or private production
evidence. An advisory assessment may consume the same source evidence, but it
is an independent activity with its own authorization. A proposed, built or
qualified livepatch is not evidence that a running system is protected.

The generic release process remains authoritative for technical admission,
payload form, catalog descriptors, emitted closure, qualification, operation
and recovery. Do not copy those requirements into the selection record.

## Freeze the selection inputs

Assign a proposal ID and revision before enumeration. Record the following
inputs with immutable revisions or retrieval times:

| Input | Required identity and scope |
| --- | --- |
| Exact target | Configured kernel package, downstream Linux commit, vpsAdminOS revision and configuration inputs |
| Running-build scope | Supported running builds that the proposed livepatch is expected to cover |
| Stable source range | Stable branch, lower endpoint excluded, upper endpoint included, peeled tag commits and ancestry proof |
| Primary security source | Linux CNA snapshot or retrieval time and immutable record references when an assigned record exists; stable source identity for a source-proven unassigned security fix |
| Existing coverage | Target livepatch page, catalog and selected source revisions; supplied active-stack facts when available |
| Selection policy | Kernel CVE selection policy revision, threat breadth and completeness claim |
| Intended result | Livepatch consumer, any separately requested advisory consumer and currently authorized phase |

Express the source interval as `LOWER_EXCLUSIVE..UPPER_INCLUSIVE`. If the
request names the first fixing release rather than an already-covered lower
endpoint, use that release's immediate predecessor as the excluded endpoint.
Verify both endpoint commits and prove that the upper endpoint descends from
the lower one. Version names alone are insufficient.

Check prior native-kernel and livepatch coverage against the pinned target
page, catalog and source. When actual running-stack information is not part of
the authorized inputs, record it as unknown. Do not infer fleet state from the
repository configuration or require a vpsAdmin read to continue selection.

## Enumerate issues and exact source fixes

Enumerate every stable change in the frozen interval before applying relevance
or livepatch-suitability filters. Join primary security records to exact stable
corrective commits and the first stable release containing each correction.
Check commit references as well as affected-version ranges. CVE numbering and
publication dates do not define source membership.

Keep commits without a current CVE association in the source inventory so that
unassigned security fixes, later corrections and prerequisites are not lost.
Missing a CVE does not establish either security relevance or irrelevance. Give
non-security changes an explicit outside-scope disposition; assess a
prerequisite as part of the selected vulnerability's complete source group.
Distinguish source enumeration from individual vulnerability and
livepatch-suitability review.

For every issue or still-unassigned security fix:

1. Record the CVE and record status, or a stable local identity when no CVE is
   assigned.
2. When assigned, record the primary record snapshot. Always record the exact
   mainline and stable corrective commits and the first containing stable
   release.
3. Identify ineffective fixes, later corrections, rejected or withdrawn
   records, and replacement IDs without silently removing them from the
   enumeration.
4. Map the complete ordered fix group. One issue may require several source
   commits, and one commit may address several issues.
5. Follow every prerequisite transitively, including dependencies outside the
   selected interval. Record its exact commit and why it is required.
6. Review each source change against the exact downstream target. Stable
   ancestry, a matching subject or a clean textual application does not prove
   target applicability.

Reconcile the final candidate counts with the mechanical interval enumeration.
State how many changes and security records were found, how many received
individual source review, how corrections and shared commits were counted, and
which items remain unresolved. Keep zero-hit releases in the count record.

## Make independent relevance and livepatch judgments

Record member relevance and platform exposure separately using the linked CVE
selection policy:

- relevance: `propose`, `conditional_review`, `defer` or `exclude`;
- exposure: `affected`, `not_affected`, `conditional`, `unknown` or
  `unassessed`.

Give every conclusion an exact build, configuration, role and time scope when
those facts matter. A current fixed kernel does not prove that older builds
were unaffected. Missing configuration or runtime evidence remains an
uncertainty; it does not become a negative conclusion.

Assess the vulnerable operation against the exact target source and its
supported configurations. Include facilities available through explicit host
or container configuration, such as KVM exposed to vpsAdminOS containers
through `/dev/kvm`. A module need not load by default for its vulnerabilities
to matter.

Absence from the default boot-module list, denied automatic module loading or a
currently unobserved workload does not justify exclusion. Neither do
administrative privilege requirements, optional device delegation, impact
confined to a container, or the absence of a demonstrated container escape.
Record these as prerequisites or prioritization evidence and assess the
vulnerable operation itself.

An exclusion needs positive evidence for the stated target scope: an
incompatible architecture, absent defective code, an equivalent complete fix
already present, or code that the exact target configuration cannot provide in
any supported form. Changes confined to tests, documentation, tooling or
release metadata may be outside scope when they contain no shipped runtime
security correction. Keep reverted or superseded changes linked to the
effective correction. Missing evidence remains unresolved; it is not proof of
non-exposure.

Independently assign one livepatch-suitability result:

- `candidate`: the complete fix group applies to the exact target and can
  proceed to the generic process;
- `conditional`: a named prerequisite or source/applicability question must be
  resolved or included with the fix;
- `native_update`: the security fix is relevant but should be delivered by a
  native kernel update;
- `unsafe_or_unsupported`: the fix cannot satisfy the existing livepatch
  safety or reversal contract; or
- `unassessed`: source or target evidence is not yet sufficient for a
  livepatch decision.

Base livepatch suitability on the exact target, complete prerequisite group,
affected objects and functions, expected emitted-function and symbol-position
closure, overlap with existing batches, predecessor lineage and whether the
generic qualification process can establish safe operation and reversal. Do
not force a fix into a livepatch merely because it is member-relevant. Do not
drop an otherwise suitable livepatch fix merely because no advisory is being
prepared.

Treat the number of changed functions and hot-path reach as reasons for closer
assessment, not evidence that a fix is unsafe to livepatch. For an important
applicable fix, trace the target's active-object and old/new transition
invariants before recommending a native-only response. If that assessment is
incomplete, record a `conditional` or `unassessed` result and name the missing
evidence. Use `unsafe_or_unsupported` only for an identified compatibility,
transition or artifact limitation, and describe it. Source assessment does not
replace artifact qualification.

## Prepare the approval packet

Keep the pre-approval packet with the initiative's research record. It is a
review record, not a repository schema, livepatch descriptor or target-page
extension. Use one row per issue/fix group and include:

| Field | Required content |
| --- | --- |
| Identity and provenance | CVE/status or unassigned security ID, primary record snapshot when assigned, exact stable fix commits, first fixing release, target/source revisions and prior native/livepatch coverage |
| Relevance and exposure | Vulnerable primitive and prerequisites, relevance decision, exposure conclusion and the exact scope of each |
| Source and dependencies | Ordered corrective commits, transitive prerequisites, later corrections, shared patches and grouping reason |
| Target and livepatch analysis | Exact-target applicability, affected objects/functions, expected closure, overlap/lineage and proposed operation-safety oracle concept |
| Livepatch suitability | `candidate`, `conditional`, `native_update`, `unsafe_or_unsupported` or `unassessed`, with supporting evidence |
| Selection disposition | Include, conditional, defer, native update or exclude, with confidence and missing evidence |
| Residual response | Risk left by a skip, safe response, owner, next evidence and escalation point |
| Approval | Proposal revision and exact livepatch fix groups approved; any advisory approval recorded separately |

Alongside the rows, include the pinned input table, enumeration counts,
completeness claim and unresolved limits. The packet may link primary records
and the vpsAdminOS target page. It must not depend on dossier files, vpsAdmin
reads or private production evidence to explain why a fix was selected.

## Obtain approval before authoring payloads

Present the exact proposal revision and named livepatch fix groups for user
approval. Do not author patch payloads, batch descriptors, series entries or a
new target-page release section until that selection is approved. Approval of
the process or research phase alone is insufficient.

Approval covers only the named livepatch groups at the stated target and
proposal revision. It does not include conditional or deferred rows unless
they are named explicitly. Obtain renewed direction when:

- another issue or fix is added;
- a fix group gains a substantive prerequisite;
- the exact target changes; or
- the proposed technical response changes materially.

Editorial changes and corrections to citation text or links do not require a
new selection decision when they preserve the same selected source object and
content. A change to a corrective commit, selected source object or selected
payload requires renewed approval, even when the CVE or fix-group name is
unchanged. Ordinary backport adaptation of the approved source after handoff is
reviewed under the generic process; it does not add a selection approval gate
for each implementation edit. Advisory dossier preparation, livepatch rollout,
repository integration, advisory publication and email each retain their
separate authorization boundaries.

A user-supplied exact fix does not acquire this range-selection gate. Route it
directly to the generic release process under the user's request and that
process's ordinary source, dependency, applicability and safety checks.

## Hand approved fixes to the generic process

For each approved fix group, hand the generic process:

- the exact CVE or unassigned-fix identity and primary source references;
- canonical source repository and full ordered corrective commits;
- every transitive prerequisite and shared-patch relation;
- source-review and exact-target-applicability conclusions;
- affected objects/functions and expected emitted closure;
- existing-batch overlap and predecessor-lineage findings; and
- important exclusions or unresolved residual risks that constrain the batch.

An approved fix group may require
[ordered stages across consecutive batches](process.md#ordered-fix-stages).
Hand over the complete group and its required forward and reverse sequence;
record partial stages separately from the first complete correction.

The generic process then creates and verifies its existing provenance,
descriptor, series, target-page and qualification artifacts. Packet-level
exclusions remain in the selection record; they do not become universal fields
in every livepatch target page. If advisory work is also approved, start its
existing dossier and evaluation workflow independently from the shared source
evidence.

## Record addressed issue coverage

During authoring and finalization of every approved batch, update the existing
`docs/os/livepatches/<kernel-version>.md` target page before declaring the batch
ready. This applies to range-selected and directly supplied fixes. The target
page provides a quick lookup over its authoritative release sections and the
fix descriptors; it is not another patch registry.

Add one coverage-index row for every addressed issue, including an issue with
no assigned CVE. Record:

- the stable issue or fix identity and all assigned CVEs;
- the correction and its affected scope;
- the first complete, effective correcting livepatch, linked to its release
  section;
- the fix IDs, canonical source repository and full commits, and first
  containing stable release or other truthful provenance; and
- the existing qualification and operator status, linked to details instead
  of copying volatile evidence.

Keep the first correcting release when additive successors continue to provide
the fix. An ineffective earlier attempt is not the first complete correction;
record the later correction truthfully. Do not list skipped or merely proposed
work as addressed. An authored but unqualified batch may be indexed only with
an explicit blocked or unqualified status, never as delivered or available.
Source inclusion, qualification, operator availability and per-node activation
are separate facts. The target page does not establish per-node activation.

Before readiness, compare the index and release section with the final fix
descriptors and ordered payload ownership. They must identify the same immutable
fix, source and payload mapping. A CVE assigned after publication may be added
as an explicitly verified later association to that same mapping while the
original producer CVE metadata remains unchanged. Preserve the first correcting
release and do not imply a new payload, qualification or deployment. For an
unpublished candidate, update its descriptor and repeat the identity and build
checks required by the generic process. Keep captures, store paths and checksums
in the existing release evidence.

## Preserve skipped fixes and residual responses

Never silently discard an important or uncertain fix. Keep it in the packet
until its response is complete or a later reviewed proposal supersedes it.

| Condition | Livepatch suitability | Selection action and required response |
| --- | --- | --- |
| Not member-relevant after review | Preserve the assessed result, or use `unassessed` when no suitability review was performed | `exclude`; record the concrete scope reason and why title or score does not change it |
| Relevance or target applicability unresolved | `unassessed`, or `conditional` when a named condition can resolve the question | `defer`; identify the missing primary, source or configuration evidence and its owner |
| A required dependency lies outside the range or materially changes semantics | `conditional` | Select `conditional` or include the complete group; do not select the visible correction alone |
| Emitted closure, lineage, artifact admission, platform safety or reversal cannot meet the generic process | `unsafe_or_unsupported` | `exclude` from livepatching or select a native update; recommend further engineering when appropriate |
| Security-relevant but suitable only for a native kernel update | `native_update` | Select a native update; preserve residual exposure and any separately considered advisory response |
| Intentionally postponed with material residual exposure | Preserve the assessed `candidate` or `conditional` result | `defer`; escalate the severity, evidence, affected scope and interim protection to the user, with a dated or event-bound next decision |

A relevant vulnerability that cannot be safely livepatched stays in the result
with the required native kernel update and reboot, its residual risk and any
supported interim response.

Loading a preventive livepatch is not recovery for a system that has already
hit the failure. The generic process and target page own activation, rollback
and recovery requirements after an approved selection becomes a release.

[cve-selection]: https://github.com/vpsfreecz/security-advisories/blob/2026-07-13-security-advisory-automation/docs/cve-selection.md
