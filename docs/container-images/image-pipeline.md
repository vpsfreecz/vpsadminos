# Container image pipeline

The image workflow handles default-branch changes, weekly complete rebuilds and
manual image selection. It resolves the configured catalog, tags and garbage
collection rules from the checked-out source. The weekly and manual `all` modes
use the complete configured catalog; push mode expands changed scripts and shared
dependencies. Automatic selection intersects detected source images with the
configured catalog; an empty intersection skips the candidate run. Shared image
test changes rebuild all configured images. Unknown manual selections fail before
building. Removing an image from the build configuration stops future builds;
it does not withdraw previously published versions or change their retention.

The tools-owned `ImagePipeline::Worker` and `ImagePipeline::Pool` use generic
OsVm machine APIs; loading the OsVm gem does not load image pipeline policy.
Their focused tests live in `tools/image-pipeline/spec` and run in the existing RSpec CI job
using the OsVm bundle.

Each run starts a bounded pool of fresh vpsAdminOS VMs on the trusted runner.
Workers reuse their builder containers and execute one assigned image at a time.
The queue starts Guix and Gentoo early while reserving capacity for quick images.
Literal builder names provide soft affinity within the next few queued items;
workers do not wait for affinity. A quick result can upload while another worker
is still compiling a long image.

Each worker has separate disks, state, sockets and export directories. User-mode
networking has no fixed host forwarding port. Source comes from `git archive` at
the recorded commit and mounts read-only; export storage is writable and separate.
SSH credentials stay on the host, outside guest shares. Image tests run serially
inside each worker, so their fixed test subnet does not overlap another guest.

The producer sends the frozen descriptor to the service before starting the build,
then uploads each verified format and records the successful build/test outcome.
The service acknowledges durable files before the coordinator removes their local
export scratch. Source/input manifests, assignment descriptors and compact result
logs remain available as workflow artifacts. Failed or unacknowledged exports are
retained for diagnosis; admission must reserve enough scratch space for them.

Ordinary image failures do not trigger a rebuild. A diagnosed worker transport
failure replaces that worker and permits one recorded retry with the same capture
and a new item attempt. Cleanup failure cannot return a worker to the queue.
Already acknowledged images survive worker replacement. Targeted builder deletion
requires an idle owned builder CTID; `osctl-image ct del --type builder --force
CTID` can kill a running container and has no active-build ownership check.

## CI and publication

After the selected work finishes, the service seals a run only if every expected
image has a verified receipt and all declared formats. Its URL combines the pinned
public baseline with those exact replacements. Failed or missing replacements
cannot use older baseline bytes. Catalog/seal integrity errors still fail the
build pipeline in every mode.

Full integration CI runs weekly. Manual dispatch opts in with the boolean
`full_ci` input (default false); default-branch pushes run image builds, all
selected image tests and independent publication without full integration CI.
The driver forwards this request explicitly to the coordinator. Only requested
CI checks the full-suite dependencies and emits `test-config.json`; an unchanged
historical suite dependency does not fail a build-only push. A missing requested
dependency makes full CI unavailable, without rebuilding untouched images or
withdrawing independently verified receipts. Failed/unsealed candidates cannot
advertise CI readiness. Empty image selection skips the candidate, publication
and full CI. The ordinary `ci.yml` push/PR workflow remains independent.

Requested full CI receives the sealed URL through the common test configuration
and starts with fresh disks/caches. Repository readiness checks cover ordinary
pool creation; intentional custom-repository tests still use their explicit
repositories. General
integration tests boot the OS being tested, independently of the build worker VMs.

Publication runs in a separate protected job for the default source. It consumes
individually verified receipts even when another image fails and the run cannot
seal. It reads the fresh public generation, proves source ancestry and applies
the configured defaults/GC in order. A wholly superseded run cannot restore old
policy. The service rejects stale generation writes. The producer key cannot
publish, and full CI is not a universal publication gate.

## Runner admission

Enable the `container-image-builder` and `container-image-publisher` protected
environments only after verifying trusted source admission, KVM/virtiofs access,
CPU/RAM/shared-memory capacity, scratch disk headroom and service limits. Manual
nondefault refs require the same trusted builder admission and cannot publish.
Untrusted pull requests do not execute this workflow on persistent runners.

Configure `IMAGE_WORKERS`, `IMAGE_WORKER_MEMORY_MIB`, `IMAGE_WORKER_CPUS`,
`IMAGE_WORKER_DISK_SIZE`, aggregate `IMAGE_MEMORY_MIB` and `IMAGE_CPUS`,
`IMAGE_RUN_LEASE_SECONDS`, `IMAGE_REPOSITORY_URL`, and role-specific
`IMAGE_PRODUCER_TARGET`/`IMAGE_PUBLISHER_TARGET`. Supply the pinned public SSH host
key as `IMAGE_SSH_HOST_KEY`; use separate producer/publisher SSH key secrets.
Missing measured resource values fail admission. Choose finite run leases long
enough for the build and full-CI consumers; an expired run must fail explicitly.

`tools/image-pipeline/plan.nix` exports source selection/policy and the suite's
repository dependencies from `tests/image-repository-requirements.nix`. Maintain
that source-owned list with explicit suite fetch selectors, including pinned
versions and variants; intentional custom-repository fixtures stay separate.
Readiness checks exact vendor/variant/architecture and canonical versions or tags.
`tools/image-pipeline/worker.nix` exports the worker machine
closure. `tools/image-pipeline/build.rb`, run through `osvm script`, owns the worker
lifecycle and producer receipts. `tools/image-pipeline/publish.rb` consumes the
summary under publisher authority. Restricted SSH forced commands select the
service role; they do not accept a role from JSON. See the
[service control protocol](https://github.com/vpsfreecz/vpsadminos/tree/staging/osctl-repo-server).
