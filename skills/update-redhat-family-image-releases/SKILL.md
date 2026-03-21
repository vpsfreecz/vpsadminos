---
name: update-redhat-family-image-releases
description: Update Rocky Linux, AlmaLinux, Fedora, or all Red Hat-family container image release files in this repository. Use when requests mention `update rocky`, `update almalinux`, `update fedora`, `update redhat-family distributions`, or otherwise ask to bump release RPMs under `image-scripts/images/*`. Follow upstream HTTP repo directory listings, update the matching `build.sh` files, run `./test-runner.sh test image-scripts/test@image-name` for each changed image, and keep commits split per changed image directory.
---

# Update Redhat Family Image Releases

## Overview

Update the release-related lines in `image-scripts/images/{rocky-*,almalinux-*,fedora-*}/build.sh` by reading the upstream HTTP package listings and then verify each changed image with its matching `image-scripts/test@...` test.

## Quick Start

1. From repo root, run `ruby skills/update-redhat-family-image-releases/scripts/discover_release_updates.rb <scope>`.
2. Edit the `build.sh` files reported by the script.
3. Run `./test-runner.sh test image-scripts/test@<image-name>` for every changed image.
4. Keep one commit per changed image directory, for example `image-scripts: update rocky-9 to <ver>`.

Use `rocky`, `almalinux`, `fedora`, or `all` for `<scope>`.

## Workflow

### Select Targets

- `rocky`: update every `image-scripts/images/rocky-*`
- `almalinux`: update every `image-scripts/images/almalinux-*`
- `fedora`: update every `image-scripts/images/fedora-*`
- `all`: update all of the above

### Discover Exact Versions

- Never guess RPM filenames or point releases.
- Use `scripts/discover_release_updates.rb` to read the current repo state and the upstream directory listings.
- Read [references/release-workflow.md](references/release-workflow.md) only when you need the per-family URL and variable rules.
- If a stable Fedora image is no longer on the live Fedora releases mirror, treat it as stale repo content to remove instead of chasing archive URLs.

### Edit Only Release-Related Lines

- Rocky: update `POINTVER` and `RELEASE`.
- AlmaLinux 9/10/future: update `POINTVER` and `RELEASE`.
- AlmaLinux 8: update `POINTVER` and `RELEASE`, but leave `BASEURL` and `UPDATES` on `${RELVER}` unless the upstream layout changed.
- Fedora stable: update the shared release suffix in the four `fedora-release*` lines.
- Fedora rawhide: update `RAWHIDE_RELVER`; keep the four `RELEASE` lines consistent with it.

### Verify Every Changed Image

- Run `./test-runner.sh test image-scripts/test@<image-name>` for each changed image directory.
- If `osvm` or `test-runner` has local changes, run `nix develop .#test-runner -c bundle exec ./test-runner/bin/test-runner test image-scripts/test@<image-name>` from repo root so the tests use the local code.
- Do not skip a changed image because another image in the same family passed.

### Keep Commits Focused

- Make one commit per changed image directory, not one commit for the whole family sweep.
- Use subjects such as `image-scripts: update rocky-9 to <ver>`, `image-scripts: update almalinux-10 to <ver>`, or `image-scripts: update fedora-rawhide release to <ver>`.
