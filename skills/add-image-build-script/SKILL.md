---
name: add-image-build-script
description: Add new vpsAdminOS container image build scripts under `image-scripts/images/IMAGE_NAME`. Use when requests ask to add image build support for a distribution or release such as Ubuntu, Debian, Fedora, Rocky Linux, AlmaLinux, CentOS Stream, Alpine, openSUSE, Arch, Void, Gentoo, NixOS, Devuan, or similar. Covers choosing the closest existing image pattern, creating `build.sh` and `config.sh`, updating `os/configs/image-repository.nix`, integrating the image in `tests/distributions.nix`, running `image-scripts/test@IMAGE_NAME`, fixing build or container-test failures, and preparing a focused commit.
---

# Add Image Build Script

## Overview

Add a new image directory in `image-scripts/images/` by following the closest existing distribution-family pattern, publish it in the image repository config, add it to the distribution test matrix, and verify it with the matching image-scripts VM test.

## Workflow

1. Locate the vpsAdminOS repo root. Expect `image-scripts/README.md`, `image-scripts/include/`, `image-scripts/images/`, `os/configs/image-repository.nix`, `tests/distributions.nix`, and `tests/all-tests.nix`.
2. Read `image-scripts/README.md` sections "Contributing build scripts", "How does it work", "Image name and variables", and "Builders" when the current local conventions are not fresh in context.
3. Determine the target image name from the request. Prefer the existing naming scheme `<dist>[-<relver>[-<arch>[-<vendor>[-<variant>]]]]`, for example `ubuntu-26.04`, `debian-13`, or `fedora-43`.
4. Inspect the closest existing image directory in the same family and a close release, plus the matching `include/*.sh`, `builders/*`, repository config, and test distribution entries.
5. Create or update the required files:
   - `image-scripts/images/<image-name>/config.sh`
   - `image-scripts/images/<image-name>/build.sh`
   - any extra family-specific files used by nearby images, such as cgroup init scripts
   - `image-scripts/builders/<builder>/{config.sh,setup.sh}` only when no existing builder fits
   - `os/configs/image-repository.nix`
   - `tests/distributions.nix`
6. Run syntax checks and the targeted `image-scripts/test@<image-name>` test.
7. Fix build, boot, or test failures and rerun the targeted test until it passes or an external blocker is identified.
8. If asked to commit, make a focused commit with pre-commit hooks enabled.

## Inspect Existing Patterns

Start with local code, not assumptions:

```bash
find image-scripts/images -maxdepth 2 -type f -name build.sh | sort
find image-scripts/builders -maxdepth 2 -type f | sort
sed -n '1,220p' image-scripts/images/<nearest>/build.sh
sed -n '1,120p' image-scripts/images/<nearest>/config.sh
sed -n '1,260p' image-scripts/include/<family>.sh
sed -n '1,260p' os/configs/image-repository.nix
sed -n '1,260p' tests/distributions.nix
```

Use these common family anchors:

- Debian and Ubuntu: copy the nearest `debian-*` or `ubuntu-*`, source `include/debian.sh`, and use an existing Debian/Ubuntu builder.
- Fedora, Rocky Linux, AlmaLinux, and CentOS Stream: copy the nearest same-family image, source `include/redhat-family.sh`, and keep release RPM URLs exact.
- Alpine, Arch, Devuan, Gentoo, NixOS, openSUSE, Void, Slackware, Chimera, and Guix: copy the nearest same-family image and inspect its family include before changing behavior.

For Red Hat-family release bumps to existing images, use `$update-redhat-family-image-releases` instead. For adding a new Red Hat-family image, reuse that skill's release discovery rules when exact RPM versions are needed.

## Implement The Image

`config.sh` should normally be minimal:

```bash
BUILDER=<existing-builder>
```

Add `DISTNAME`, `RELVER`, `ARCH`, `VENDOR`, `VARIANT`, or `DATASETS` only when the image name cannot express the value or existing nearby images require it.

Keep `build.sh` close to the nearest existing family script:

```bash
. "$IMAGEDIR/config.sh"
# distribution-specific variables such as RELNAME, BASEURL, RELEASE, EXTRAPKGS

. "$INCLUDE/<family>.sh"
. "$INCLUDE/systemd.sh"  # only when nearby systemd images do this

bootstrap
configure-common
# family-specific configuration calls
# distribution-specific configure-append blocks
configure-systemd-console-getty  # only when using systemd include
run-configure
```

Rules:

- Preserve local shell style from neighboring files. Do not refactor unrelated scripts.
- Verify current upstream release names, mirrors, package filenames, and RPM/deb package names. Do not guess time-sensitive values.
- Keep package lists minimal and consistent with nearby images.
- Avoid adding `abstract` to a real image directory; `tests/all-tests.nix` skips image directories containing `abstract`.
- If adding a reusable family helper in `image-scripts/include/`, update only the shared logic needed by the new image and check all affected existing images.

## Container Compatibility

Remember that these images are for vpsAdminOS containers, not full VMs. They run under a custom vpsAdminOS kernel and LXC containers with user namespaces. A distribution may try to start services that need real hardware, privileged kernel features, kernel module loading, host-level audit, firmware, or boot-time device management. Those units must be disabled, masked, removed, or configured to degrade cleanly.

When `image-scripts/test@<image-name>` fails after the image is built, inspect the failure as a container compatibility problem first:

- Read the test log for failed package installs, failed chroot configuration, failed container start, failed stop, or service timeout.
- Compare with masks in the closest family include before adding new ones.
- For systemd images, common local patterns include masking or disabling audit, kdump, plymouth, tuned, rngd, kernel debug/config mounts, binfmt_misc mounts, NFS rpc pipefs, hardware console services, hostnamed, module loading, and services that assume full device ownership.
- Preserve required container behavior: SSH login, basic networking, locale setup, `/run`, `/run/udev`, hostname handling, clean start/stop, and cgroup behavior expected by `tests/distributions.nix`.
- Prefer targeted masks or service overrides over broad removal when neighboring images use that approach.
- For udev-trigger problems, follow the local pattern that limits `systemd-udev-trigger.service` to network devices instead of trying to trigger all host hardware.

## Builders

Prefer an existing builder from `image-scripts/builders/`. Add a new builder only when the target distribution cannot be built with an existing one.

When adding a builder:

- Create `image-scripts/builders/<builder>/config.sh` with the base image metadata.
- Create `image-scripts/builders/<builder>/setup.sh` with only packages required to run the image build script.
- Copy the nearest builder pattern in the same family before inventing commands.

## Repository Config

Update `os/configs/image-repository.nix` so the new image can be built into the vpsAdminOS image repository.

Rules:

- Add the image under `services.osctl.image-repository.vpsadminos.images` in the matching distribution attribute.
- Keep the structure used by the family: nested version attrs for versioned releases, `.rolling` entries with `name = "<distribution>"` for rolling images, and variants such as `glibc`, `musl`, `systemd`, `openrc`, or `impermanence` where the existing family uses them.
- Add or adjust tags only with intent. `latest` and `stable` should point at the current preferred stable image for that distribution; do not leave competing `latest` or `stable` tags on superseded releases unless the existing family explicitly does so.
- Add garbage-collection entries for rolling or date-stamped versions when matching existing families do this.
- Keep Nix formatting consistent and run the repository formatter or existing pre-commit hook when committing.

## Distribution Tests

Update `tests/distributions.nix` so distribution-level tests can create containers from the new image.

Rules:

- Add a table entry whose `distribution` and `version` match the repository image name or tag used by `osctl ct new --distribution ... --version ...`.
- Add the entry to the correct cgroup group:
  - `cgroupAll` for images expected to work on both cgroups v1 and v2.
  - `cgroupv2` for modern images that require cgroups v2. Put distributions using systemd 258 or newer here, even when an older release in the same family is in `cgroupAll`.
  - `cgroupv1` only for legacy images that cannot boot on cgroups v2.
- Add the entry to exactly one init-system group: `systemd` or `non-systemd`.
- Use the closest existing distribution as the starting point, then verify the new release's init system and cgroup support. Do not copy the cgroup group blindly across major releases.
- If a dist-config test fails because a service cannot run in an LXC/user-namespace container, fix the image script or family include with a targeted mask/override and rerun the affected test when practical.

## Test And Validate

Run cheap checks first:

```bash
bash -n image-scripts/images/<image-name>/build.sh
bash -n image-scripts/images/<image-name>/config.sh
```

Check that the generated test exists. Image tests are auto-discovered from `image-scripts/images/` by `tests/all-tests.nix`, excluding directories with `abstract`:

```bash
./test-runner.sh ls 'image-scripts/test@<image-name>'
```

Run the targeted VM test:

```bash
./test-runner.sh test image-scripts/test@<image-name>
```

If `osvm` or `test-runner` has local changes, run under the test-runner development shell from the repo root:

```bash
nix develop .#test-runner --command bundle exec ./test-runner/bin/test-runner test image-scripts/test@<image-name>
```

If the test fails, fix the script, repository config, builder, or service masks and run it again. Do not claim the image is verified unless the matching `image-scripts/test@<image-name>` test passed. If the test is too expensive or blocked, state the exact command that was not run and why.

After editing `tests/distributions.nix`, list the affected distribution tests:

```bash
./test-runner.sh ls 'dist-config/*'
```

Run targeted dist-config tests when the change is likely to affect container boot, start/stop, cgroups, `/run`, or init-system behavior. Prioritize:

```bash
./test-runner.sh test 'dist-config/start-stop'
./test-runner.sh test 'dist-config/systemd-rundir'      # systemd images
./test-runner.sh test 'dist-config/nonsystemd-rundir'   # non-systemd images
```

If these tests fail for the new distribution, treat the failure as part of the image integration and fix it unless the user explicitly scoped verification to the image build only.

## Commit

Commit only when asked. Keep the commit focused on the new image, repository config entry, distribution test entry, and any required shared helper or builder files. Write the commit message to a temporary file and use `git commit -F <tempfile>`.

Use a subject like:

```text
image-scripts: add <image-name>
```

In the body, explain what image support was added and why the chosen builder or family pattern is needed. Keep all lines at 80 characters or fewer and do not bypass overcommit hooks.
