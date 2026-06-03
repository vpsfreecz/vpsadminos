# Porting vpsAdminOS to a New Nixpkgs Release

This document describes the expected process for moving vpsAdminOS from one
NixOS/nixpkgs release to another, for example from `25.11` to `26.05`.

The main rule is to keep the port reviewable. Compatibility changes, release
version changes, and generated gem metadata belong in separate commits.

## Preparation

1. Read the NixOS release announcement and release notes for the target
   release.
2. Create a feature branch and worktree.
3. Confirm the current base branch and recent generated gem commit.
4. Enter the development shell before running repository tools:

```shell
nix develop
```

5. Install or sign hooks before committing:

```shell
overcommit --sign
overcommit --install
```

## Update Nixpkgs

Change `inputs.nixpkgs.url` in `flake.nix` to the target release:

```nix
inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-<release>";
```

Then update the lock file:

```shell
nix flake lock --update-input nixpkgs
```

Keep unrelated inputs unchanged unless evaluation or build failures show that
they must move as part of the same port.

## Evaluate Before Broad Edits

Start with focused evaluations. They fail faster and make module option
breakage easier to identify than a full system build:

```shell
nix eval --raw .#checks.x86_64-linux.os-eval.drvPath
nix eval --raw .#packages.x86_64-linux.toplevel.drvPath
nix eval --raw .#packages.x86_64-linux.template-stable.drvPath
nix eval --raw .#packages.x86_64-linux.template-impermanence-stable.drvPath
```

Use evaluation failures to update:

- compatibility options in `os/modules/nixos-compat.nix`;
- imported or renamed NixOS module options;
- local overlays in `os/overlays/`;
- local packages in `os/packages/`.

Prefer source-level package fixes over weakening compiler or linker checks
globally.

## Container Templates

For a stable NixOS release port, update the stable container surface:

1. Add `os/lib/nixos-container/stable/vpsadminos-<release>.nix`.
2. Keep `os/lib/nixos-container/stable/vpsadminos.nix` compatible with the
   current stable release.
3. Export the versioned module from `flake.nix` as
   `nixosModules.container_<release_with_underscores>`.
4. Add image scripts under:
   - `image-scripts/images/nixos-<release>/`
   - `image-scripts/images/nixos-<release>-impermanence/`
5. Move `latest` and `stable` tags in `os/configs/image-repository.nix` only
   after the corresponding templates build.

Build the templates:

```shell
nix build .#template-stable .#template-impermanence-stable --no-link
```

## Version Bump

Run the vpsAdminOS version bump only after the compatibility changes are
identified:

```shell
make version VERSION=<release>
```

This changes version constants, man page version strings, and related release
metadata. Keep these changes in their own commit. Do not mix them with Nix
module fixes, package fixes, or template logic.

## Gem Rebuilds

When Ruby code or gem versions change, rebuild packaged gems. Use one build id
for the whole generated package set:

```shell
BUILD_ID=$(date -u +%Y%m%d%H%M%S)
make gems BUILD_ID=$BUILD_ID
make osctl-env-exec BUILD_ID=$BUILD_ID
```

`make gems` rebuilds the main vpsAdminOS gems. `osctl-env-exec` has a separate
Makefile target and should be rebuilt with the same build id when its gemspec
version changed.

If a native dependency fails to build, fix and publish that dependency first,
then update the relevant vpsAdminOS gemspec and rerun the gem rebuild. For
example, `osctld` depends on `ruby-lxc`, so a Ruby C API break in `ruby-lxc`
must be fixed before regenerating the `osctld` package metadata.

Generated gem metadata is committed separately. The generated gem commit should
contain only:

- `.build_id`;
- `os/packages/**/Gemfile`;
- `os/packages/**/Gemfile.lock`;
- `os/packages/**/gemset.nix`.

Use the existing generated commit subject style:

```text
os: update gems to <version>.build<build_id>
```

## Validation

At minimum, validate evaluation, templates, and the host OS closure:

```shell
nix eval --raw .#checks.x86_64-linux.os-eval.drvPath
nix eval --raw .#packages.x86_64-linux.toplevel.drvPath
nix build .#template-stable .#template-impermanence-stable --no-link
nix build .#toplevel --no-link
```

Search for stale generated pins after gem rebuilds:

```shell
rg '<old-version>|<old-build-id>|<old-native-gem-version>' \
  os/packages osctld/osctld.gemspec .build_id
```

Run targeted tests according to the affected surface. For container template
ports, prefer image repository and NixOS container smoke tests first, then
broaden to the relevant `osctl/*` or CI subset if shared behavior changed.

## Commit Structure

Use this order:

1. Compatibility and porting code.
   - Nixpkgs input and lock update.
   - NixOS option/module compatibility.
   - Container module and image script updates.
   - Local overlay/package fixes.
   - Dependency version requirements such as native gem dependencies.
2. vpsAdminOS version bump from `make version`.
3. Generated packaged gem update from `make gems` and related targets.
4. Documentation or follow-up notes.

Each non-generated commit message must explain why the change is needed.
Generated gem commits use the subject-only style described above.

## Compatibility Notes

Before merging or deploying, check whether the port changes any of:

- osctld persisted state or on-disk formats;
- ZFS feature defaults or rollback behavior;
- vpsAdminOS module options consumed by configuration repositories;
- generated NixOS container modules or image metadata;
- APIs or protocols between vpsAdmin, osctld, osctl, and osctl-image.

A pure nixpkgs release port should normally avoid state format changes. If a
state or protocol change becomes necessary, document deployment ordering and
rollback implications in the commit or accompanying plan.
