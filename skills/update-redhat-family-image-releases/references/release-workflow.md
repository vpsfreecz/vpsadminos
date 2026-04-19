# Release Workflow

## Targets

- Rocky images live in `image-scripts/images/rocky-*`.
- AlmaLinux images live in `image-scripts/images/almalinux-*`.
- CentOS Stream images live in `image-scripts/images/centos-*-stream`.
- Fedora images live in `image-scripts/images/fedora-*`.
- The matching verification test is always `./test-runner.sh test image-scripts/test@<directory-name>`.

## Rocky

- Discover the current point release from `https://ftp.linux.cz/pub/linux/rocky/`.
- For each major version, inspect `https://ftp.linux.cz/pub/linux/rocky/<POINTVER>/BaseOS/x86_64/os/Packages/r/`.
- Select the highest `rocky-release-<POINTVER>-*.rpm` from that listing.
- Update `POINTVER` and `RELEASE` in `image-scripts/images/rocky-*/build.sh`.
- `BASEURL` and `UPDATES` already follow `${POINTVER}` and should stay aligned through that variable.

## AlmaLinux

- Discover the current point release from `https://repo.almalinux.org/almalinux/`.
- For each major version, inspect `https://repo.almalinux.org/almalinux/<POINTVER>/BaseOS/x86_64/os/Packages/`.
- Select the highest `almalinux-release-<POINTVER>-*.rpm` from that listing.
- Update `POINTVER` and `RELEASE` in `image-scripts/images/almalinux-*/build.sh`.
- `almalinux-8` is a special case: keep `BASEURL` and `UPDATES` on `${RELVER}` unless the upstream layout changes, because only the release package name uses `${POINTVER}` there.

## CentOS Stream

- Inspect `https://mirror.stream.centos.org/<MAJOR>-stream/BaseOS/x86_64/os/Packages/`.
- Select the highest `centos-stream-release-<POINTVER>-*.rpm` from that listing.
- Update `RELEASE` in `image-scripts/images/centos-*-stream/build.sh` to that exact RPM path.
- Keep `BASEURL` and `UPDATES` on `http://mirror.stream.centos.org/<MAJOR>-stream/...` unless the upstream layout changes.
- If the newest RPM embeds a different `<POINTVER>` than the current file, update `POINTVER` to match it. In current CentOS Stream images, history shows `POINTVER` has stayed on `<MAJOR>.0` while only the RPM release suffix changes.

## Fedora Stable

- Inspect `http://ftp.fi.muni.cz/pub/linux/fedora/linux/releases/<RELVER>/Everything/x86_64/os/Packages/f/`.
- If that live mirror no longer carries a Fedora release still present in this repo, treat that image as stale and remove its build script instead of switching to archive URLs.
- Find the highest release suffix that exists for all four packages:
  - `fedora-release-server-<RELVER>-<N>.noarch.rpm`
  - `fedora-release-<RELVER>-<N>.noarch.rpm`
  - `fedora-release-common-<RELVER>-<N>.noarch.rpm`
  - `fedora-release-identity-basic-<RELVER>-<N>.noarch.rpm`
- Update the four `RELEASE` lines in `image-scripts/images/fedora-<RELVER>/build.sh` to that shared `<N>`.

## Fedora Rawhide

- Inspect `http://ftp.fi.muni.cz/pub/linux/fedora/linux/development/rawhide/Everything/x86_64/os/Packages/f/`.
- Find the highest shared `<RAWHIDE_RELVER>` across the same four `fedora-release*` package families.
- Set `RAWHIDE_RELVER` to that shared value in `image-scripts/images/fedora-rawhide/build.sh`.
- Keep the four `RELEASE` lines interpolating the same `RAWHIDE_RELVER`.

## Verification

- Run the matching test for every changed image directory.
- If you changed `rocky-9` and `rocky-10`, run both tests separately.
- When `osvm` or `test-runner` has local changes, run `nix develop .#test-runner -c bundle exec ./test-runner/bin/test-runner test image-scripts/test@<directory-name>` from repo root.

## Useful Commands

```bash
ruby skills/update-redhat-family-image-releases/scripts/discover_release_updates.rb rocky
ruby skills/update-redhat-family-image-releases/scripts/discover_release_updates.rb almalinux
ruby skills/update-redhat-family-image-releases/scripts/discover_release_updates.rb centos-stream
ruby skills/update-redhat-family-image-releases/scripts/discover_release_updates.rb fedora
ruby skills/update-redhat-family-image-releases/scripts/discover_release_updates.rb all
```
