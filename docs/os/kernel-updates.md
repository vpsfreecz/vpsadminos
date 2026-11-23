# Updating a kernel

Use this process to add a selectable kernel version or update the stable or
unstable selection. It preserves the complete downstream behavior shipped by the
predecessor, including pristine backports and package-layer patches. The
[update-kernel skill](https://github.com/vpsfreecz/vpsadminos/tree/staging/skills/update-kernel)
routes agents here. Read the [downstream patch-series policy](patch-series-policy.md)
before changing the stack.

Keep exact revisions, generated inventories, conflict decisions and check results
in the existing Markdown release or session tracker. Derive the patch inventory
from the selected source range on every run.

## Establish the source and target

Record the requested upstream version, stable/unstable role, and whether the
request adds a version only or replaces that role's selection. For a replacement,
start from the role's current selector in `os/packages/linux/available-kernels.nix`.
For another kernel line or an add-only request, inspect the applicable catalog
entries and upstream ancestry to identify the latest applicable packaged
predecessor. Explain that choice; do not substitute the highest version across
unrelated lines, a branch tip, subject prefix or commit date. If the requested predecessor differs
from current packaging, resolve that difference before replaying.

Inspect these source interfaces together:

- `os/packages/linux/available-kernels.nix`: stable and unstable selectors.
- `os/packages/linux/catalog/<version>.nix`: per-version Linux revision and hash,
  features, configuration, package patches, ZFS pairing and retention dates.
- `os/packages/linux/packages.nix`, `default.nix`, `generic.nix`, and
  `os/modules/config/kernel.nix`: source fetching, common/version-conditional
  patches, configuration, built-in/external ZFS and module construction.
- `os/packages/zfs/`: paired ZFS source, package patches and build interfaces.
- `flake.nix` and `.github/workflows/kernels.yml`: available versions, generated
  CI closures and actual workflow triggers.

Record the predecessor's complete catalog entry and effective package layers.
Do not assume every catalog field reaches every builder; trace the actual
selected path. A patch outside the Linux Git range still needs an explicit
preservation or compatibility decision.

Use the packaged Linux revision as `old_head`. Resolve the matching upstream
release as `old_base` and the requested release as `new_base` from authoritative
upstream release history. Discover tag and peeled commit identities with
`git ls-remote` and fetch the exact required refs deliberately. Check each source
Makefile's version and ancestry. A stale downstream maintenance branch is not
authoritative when the package pins another head.

In a partial clone, keep lazy fetching disabled throughout inspection, replay
and continuation in the owned shell:

```sh
export GIT_NO_LAZY_FETCH=1
git cat-file -e "$old_head^{commit}"
```

Missing objects call for a deliberate fetch, not an accidental large promisor
download. Record the exact upstream tag objects and peeled commits after
acquisition.

In the Linux checkout, with the three verified commit IDs assigned:

```sh
git merge-base --is-ancestor "$old_base" "$old_head"
git log --reverse --format='%H %s' "$old_base..$old_head"
git rev-list --count "$old_base..$old_head"
git rev-list --merges "$old_base..$old_head"
```

Save the full generated inventory before replay. Inspect every commit in the
range, including generic fixes without `[vpsAdminOS]`. Investigate merges and
unexpected ancestry before choosing the replay shape. If reconstruction is
needed, prove that history-only step against the original before mixing in the
version port.

## Replay and resolve the whole stack

Preserve `old_head` in an exact dated local backup ref before rewriting. Retain
published refs and use an owned isolated topic branch/worktree starting at that
head. Follow the active repository/workspace branch and hook rules.

For a verified linear range, from that topic branch:

```sh
git -c rerere.enabled=false rebase --no-update-refs \
  --reapply-cherry-picks --empty=stop --onto "$new_base" "$old_base"
```

This keeps already-empty commits by default and stops when a replay becomes
empty. Inspect intentional empty commits and account for their disposition.
For a history containing merges, inspect dependencies and choose a replay that
preserves their meaning rather than blindly flattening it with this example.
Disable automatic rerere reuse, as above, or inspect every reused resolution.

If a replay stalls while classifying objects in a partial clone, distinguish
classification overhead from missing content. Stop and join only the owned
command, then reconcile HEAD, index and rebase done/todo against the saved
inventory before continuing: an interrupt can consume a todo entry before its
commit is created. Check that the required parent, old and current blobs are
available locally.
When that evidence identifies expensive promisor classification, try command-local
`-c remote.NAME.promisor=false` for each configured promisor remote on the
continuation, keeping `GIT_NO_LAZY_FETCH=1`. Substitute the actual remote names;
do not change stored clone configuration. Apply this remedy only after diagnosis.
Keep missing-content errors visible and acquire any missing objects deliberately
before proceeding.

For each conflict, read the old logical patch, the upstream change, surrounding
callers and relevant ordering, locking and lifetime rules. Preserve both the
upstream fix and downstream behavior. Resolve every conflict semantically;
wholesale ours/theirs selection or skipping a patch to evade a conflict is not a
resolution. A clean application also needs semantic review.

Record the paths, colliding changes, chosen resolution and focused checks under
the old logical owner. Fold caused compatibility repairs into that owner. Follow
the patch-series policy for identity, truthful provenance, authorship, patch
versions and chronological development history. A substantive adaptation advances
the logical patch version; an unchanged transplant does not need an artificial
version bump. Preserve independent generic fixes as independent logical patches.

## Account for every old patch

After replay, capture `new_head` and compare the complete ranges:

```sh
git log --reverse --format='%H %s' "$new_base..$new_head"
git range-diff "$old_base..$old_head" "$new_base..$new_head"
git diff --check "$new_base..$new_head"
```

Maintain one Markdown row per old logical commit in the existing tracker:

| Old commit | New commit or exact upstream equivalent | Disposition | Rationale and evidence |
| --- | --- | --- | --- |

Use unchanged, adapted or upstreamed dispositions. Review the actual patches
and final tree as well as the range-diff. Use counts and patch IDs to find
discrepancies, then inspect the source to verify behavior. Investigate every omitted, extra, empty, changed or
rerere-resolved patch; account for new prerequisites too.

An upstreamed disposition requires the exact upstream equivalent, ancestry
showing it is included in the target, and source/effect evidence that it preserves
the old intent. Only then omit a redundant replay. Raise intentional behavior
removal as a scope decision instead of labelling it upstreamed. Reconcile the
package-layer patch/configuration/ZFS inventory as well as the Git range.

Finish logical ownership, dependency order, messages and provenance. Remove
fixup/WIP residue and search changed files for conflict markers. Capture direct
review and focused checks for adapted code. Diagnose and fix build failures while
preserving every carried patch and its behavior before declaring the update ready.

## Publish the final source and register it

A dated preparation branch may publish the candidate through the authorized
feature workflow so its immutable archive is available for review and product
checks. Keep that branch and the backup refs available for recovery. After the
patch-series policy's review and exact-head validation gates pass, publish the
verified Linux head on `vpsadminos-<upstream-version>`. Do not
merge the stack into Linux's default branch or a series branch, or update a
floating series alias such as `vpsadminos-6.12` without direction.

Before publication, inspect the exact version branch:

```sh
version_branch="vpsadminos-$target_version"
git ls-remote --heads origin "refs/heads/$version_branch"
```

If it already points to `new_head`, the version branch is already published.
If absent, publish with `git push origin "$new_head:refs/heads/$version_branch"` under the task's
source-publication authorization. Read the exact remote ref again and require
its full SHA to equal `new_head`. If it points elsewhere, preserve it and inspect
why; do not force-update or repoint it to finish the task. For an intentional
later downstream revision on the same upstream version, the existing `-2`, `-3`
branch convention may be used when needed after checking current refs.

Do not create downstream release tags automatically. Reading and verifying
upstream release tags remains part of source discovery. Record the canonical
remote, full version-branch ref, freshly verified remote SHA, final tested Linux
SHA and consuming OS catalog revision/hash in the existing tracker.

The Linux builder uses `fetchurl`, so hash the GitHub archive **bytes**, not an
unpacked NAR or source tree. For the published candidate or final `new_head`:

```sh
archive_url="https://github.com/vpsfreecz/linux/archive/$new_head.tar.gz"
nix store prefetch-file --json "$archive_url"
```

Use the returned hash for the new catalog entry and realize the actual package
source to confirm it. Do not use `--unpack`. A changed final source head requires
a new archive hash; keep a single final pin rather than intermediate repins.

Add a regular `os/packages/linux/catalog/<version>.nix` file. Use the exact
`X.Y.Z` version as the filename stem and return an attribute set from the
`{ lib }:` function. Carry forward the predecessor's compatible configuration,
features, package patches and ZFS revision, hash and patches. Check the
version-conditional patches and all builder paths; a field that worked on the
predecessor may not apply to the new release.

For a new version, set `dateAdded` to the UTC date it first enters the OS
catalog (`YYYY-MM-DD`), not the upstream release date or the predecessor's
catalog date. Keep the original date when you repin a source or move a
selector. When reintroducing a retired version, check the previous catalog
record in Git and restore its original `dateAdded`. The checker cannot verify
that date automatically if the version is absent from the base tree.

Set `keepUntil` if a version must stay selectable through a particular UTC date,
for example during a rollback window. A hold can extend the 30-day minimum but
cannot shorten it. A version added on November 1 first becomes eligible on
December 2. Pruning never removes the selected stable or unstable version. If
you need a kernel that is no longer running for a future boot or rollback, set
a hold or use an older OS revision.

For a role replacement, set `stableKernelVersion` or `unstableKernelVersion` in
`available-kernels.nix` and verify the selection below. For add-only work, leave
the selectors unchanged and evaluate an explicit selection of the new version.

### Check the staged catalog

Overcommit checks the full staged catalog, including companion files. With Git,
Nix and Python 3 available, run the same check directly from the repository root:

```sh
python3 tools/kernel-entry-check.py check --as-of "$(date -u +%F)" \
  --base "$(git rev-parse HEAD)" --index
```

The check evaluates the Nix catalog without building packages or querying the
fleet. It rejects missing or unknown fields, invalid dates, dangling selectors,
and changes to `dateAdded` for versions present in the base and candidate.

### Require the kernel entry check on staging

The `kernel-entry-correctness` job checks the candidate merge commit for every
PR targeting `staging`, even when the PR does not touch kernels. After the
backfill and workflow land, use an authorized test target to verify three
cases: a valid candidate passes, an invalid candidate fails, and an unrelated
PR still reports the check. Verify that fork PRs use a read-only token and
that the test branch rule blocks a merge when the check fails or is missing.
If you use a merge queue, the check must also run on the merge group's SHA.

Before requiring the check on `staging`, verify that the branch rules let human
maintainers and scheduled writers make ordinary fast-forward updates with the
check passing on the exact commit they will push. To obtain the result, publish
the candidate on an approved development ref and dispatch **Kernel entry check**
on that ref. The workflow compares the candidate to the current `staging` tip
and rejects a candidate that no longer descends from it. Confirm the successful
result belongs to the commit to be pushed and that `staging` has not moved.

An administrator can then require the observed `kernel-entry-correctness` check
from GitHub Actions on `staging`. Confirm the result after changes to the head
or base. Keep the workflow and checker under maintainer review, and bind the
required check to the trusted workflow or source where supported. If required
checks and existing direct writers cannot work together under the branch rules,
resolve that conflict before enabling enforcement. Do not replace the existing
rules with a PR-only rule or grant the writers a standing bypass.

### Operate weekly kernel retention

The **Weekly kernel retention** workflow runs on `staging`. Once you configure
an expected fleet digest, it reports eligible kernels without changing the branch
unless `KERNEL_RETENTION_WRITE` is `true`. It keeps the selected stable and
unstable versions, kernels reported in use, and entries within their retention
period. Each retired version gets a commit titled `os: retire kernel <version>`.
That commit also removes the version's registered tests and private livepatch
and packaging files. If several versions share a payload, the commit that
retires its last supported target removes it. The workflow verifies every
commit and updates `staging` once, with a fast-forward of the whole series.

Before enabling writes:

1. Reconcile the anonymous public-status population with the independent roster
   of production machines that can run these kernels. Offline or unrepresented
   machines cannot count as evidence of non-use. Set the repository variable
   `KERNEL_RETENTION_FLEET_SHA256` to the SHA-256 of the independently reconciled
   names: lowercase each DNS name, strip one trailing dot, reject duplicates,
   sort bytewise, and encode each name as UTF-8 followed by one newline. Never
   derive the expected digest from the public-status response. Keep fleet
   identities and projections out of Git, logs and uploaded artifacts.
2. Run the workflow with writes disabled and compare the report with the fleet.
   Missing, stale, or unrecognized data blocks pruning, as does a membership
   mismatch. Reconcile membership changes before refreshing the digest. If the
   public API cannot cover the fleet, leave writes disabled. The workflow does
   not use a production API token.
3. On an equivalent test target, prove the built-in GitHub Actions token may
   publish a disposable candidate ref, dispatch the read-only entry check, and
   make an ordinary fast-forward with success on that exact commit. Verify a
   missing check, moved tip, or newly in-use kernel stops the update. Existing
   **Daily update** and **Update flake inputs** jobs also push directly; resolve
   their exact-commit admission before making the check required on `staging`.
   Do not grant an exemption or relax protections to enable this job.
4. Set `KERNEL_RETENTION_WRITE` to `true` only after those checks succeed. The
   writer repolls the fleet on the original base after GitHub reports success;
   it abandons the attempt if eligibility, coverage or the branch tip changes.
   The run leaves its `kernel-retention-candidate-*` ref as exact-check evidence.
   A stale attempt is not retried against a new base.

Pruning removes selections from future OS revisions. It does not uninstall a
running kernel. Git cannot prevent a concurrent node boot. Before rolling out
or rolling back to an older kernel, or reverting a cleanup, disable new writes
by setting `KERNEL_RETENTION_WRITE` to `false`. Cancel or let previously queued
and running retention workflows finish: changing the variable does not stop a
publisher that already started. Confirm no publisher can still push, then
check the current `staging` tip before proceeding.

To restore one version, start by reverting its retirement commit. If a later
commit removed a shared payload that version needs, restore the payload too.
Revert the affected commits newest first, including the commit that removed
that payload, or restore the required files from the original base in a
reviewed recovery commit. To undo the whole series, revert every retirement
commit from newest to oldest.

Verify the restored catalog entries and original `dateAdded` values, tests,
livepatch target matches, and documentation navigation. Resolve any navigation
conflicts before resuming. Add a `keepUntil` hold or fix fleet coverage before
re-enabling writes. Older OS revisions remain selectable subject to binary
cache availability.

## Verify the selected product

Enter the repository's `nix develop` environment. Enumerate the catalog with
`nix eval --json .#lib.kernelVersions`. Evaluate both role defaults and the actual
package sources; this example uses the normal QEMU configuration:

```sh
nix eval --json --impure --expr '
  let
    f = builtins.getFlake (toString ./.);
    inspect = unstable:
      let
        c = (f.lib.vpsadminosSystem {
          system = builtins.currentSystem;
          modules = [ ./os/configs/qemu.nix {
            system.vpsadminos.enableUnstable = unstable;
          } ];
        }).config;
      in {
        selected = c.boot.kernelVersion;
        linuxVersion = c.boot.kernelPackage.version;
        linuxSource = toString c.boot.kernelPackage.src;
        linuxDrv = c.boot.kernelPackage.drvPath;
        zfsUserSource = toString c.boot.zfsUserPackage.src;
        zfsBuiltinSource = toString c.boot.zfsBuiltinPkg.src;
      };
  in { stable = inspect false; unstable = inspect true; }
'
```

Compare the selected entry's revision/hash with the evaluated source derivation
and its URL/hash inputs. Check the requested role resolves to the target and the
other role and retained entries remain unchanged. For add-only or explicit-pin
checks, add `{ boot.kernelVersion = "TARGET"; }` to the evaluated modules with
the actual target substituted. Evaluate built-in and external ZFS paths where
affected, and inspect their actual package patches and source identities.

Realize only `c.boot.kernelPackage.src` from the same system expression with
`nix build --no-link --impure --expr` to verify the fixed-output archive without
starting compilation. Preserve the source path/derivation and relevant flake
inputs. Run Nix formatting and required hooks. For process changes, validate the
skill using skill-creator's `quick_validate.py`, inspect metadata, links and
examples, and run `make doc` in the declared environment.

Review all intended final commits, the complete Linux ranges/correspondence and
OS diff under the active independent-review rules before long product checks.
Include package-layer decisions, documentation placement, exact source pins and
history/migration provenance in that review.

The kernel workflow derives its matrix from all catalog keys. Its triggers are
specified in `.github/workflows/kernels.yml`; an ordinary feature-branch push
does not itself trigger the kernel build. Evaluate the generated target output,
then build the exact pinned closure using the existing entry point:

```sh
kernel_output_version=$(printf '%s' "$target_version" | tr '.-' '__')
nix eval --raw ".#ci-toplevel-kernel-$kernel_output_version.drvPath"
make OUTPUT="ci-toplevel-kernel-$kernel_output_version" toplevel
```

This closure includes the kernel dev and builtins-config dev outputs needed by
subsequent consumers. Use the binary cache and diagnose a miss before accepting
an unexpected local kernel build. Local compilation is expected when intentionally
changing kernel sources/configuration or when the responsible runner has not
published that derivation; record the reason. Monitor long checks under the
active environment's verification procedure and avoid redundant builds.

Select existing focused VM tests with `./test-runner.sh ls '<pattern>'`, then
run them with `./test-runner.sh test <pattern>`. Check their evaluated guest
kernel and assert actual booted release/source identity. Stable/unstable overrides
and explicit pins can make a green test irrelevant to this target. Choose
coverage for adapted behavior, boot/module loading, and affected built-in/external
ZFS modes using [testing](testing.md); do not silently retarget unrelated tests.
Record exact heads, inputs, outputs, results and checks that remain unrun.

## Compatibility and recovery

Assess each update's kernel/userspace interfaces, external modules, ZFS pairing,
persisted formats and mixed-version behavior. A version bump does not establish
compatibility by itself. Rebuild external modules against the new kernel; do not
reuse the old module directory or build identity. Existing livepatches remain
bound to their exact target identity and need their own qualification process.

In an interrupted replay, preserve uncertain edits before repair. `git rebase
--abort` in the owned worktree returns to the saved start; the backup ref remains
available. Do not reset shared or peer worktrees. Source/hash or product failures
must be diagnosed and corrected before claiming readiness.

Keep old catalog entries and OS generations for recovery. Deployment is a
separate authorized operation: prepare the exact paired closure, choose rollout
ordering and reboot requirements, and verify effects incrementally. Record when
mixed versions are supported or a coordinated update is necessary. Old generations
are a rollback path only while new persisted state and ZFS pool features remain
compatible; do not enable new pool features as part of a kernel-only update.

The reviewed and verified version branch completes Linux source publication. The
OS catalog continues to pin the full immutable Linux commit and archive-byte
hash, never the moving branch name. OS integration and other repositories retain
their own explicit approval, final-head review and check requirements. Deployment
is a separate action. Tune this process from demonstrated execution gaps and
keep individual run results in the tracker.
