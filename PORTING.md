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

If the release channel does not exist yet, use an exact nixpkgs revision
from a channel that reports the target release in `lib/.version`. Do not pin
the moving `nixos-unstable` branch as the primary input. Once the release
channel exists, switch to it and repeat validation against the new lock.

Update the primary lock entry:

```shell
nix flake update nixpkgs
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
5. Keep the build input and guest compatibility module matched to each image's
   release, including any previous releases still offered in the repository.
   A pre-release image can be registered by name. Move `latest` and `stable`
   tags in `os/configs/image-repository.nix` only once the release channel is
   available and the corresponding templates build.

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

The Nix packages build the vpsAdminOS gems from local source. When their
versions change, update the exact local gem requirements in
`os/packages/*/Gemfile`, then regenerate the package metadata:

```shell
make -B gems
```

This includes `osctl-env-exec`. Forcing the targets also regenerates
`osctl-exportfs` and `osctl-image`, whose target names match directories.
This step does not need a build ID or a gem upload. If a native dependency
fails against the new toolchain, fix the owning dependency and update its
pin separately. Review external dependency changes rather than carrying
unrelated version bumps in the port.

Commit the changes to `os/packages/*/{Gemfile,Gemfile.lock,gemset.nix}`
separately. Use the subject-only message `os: update packaged gem dependencies`.

## Validation

At minimum, validate evaluation, templates, and the host OS closure:

```shell
nix eval --raw .#checks.x86_64-linux.os-eval.drvPath
nix eval --raw .#packages.x86_64-linux.toplevel.drvPath
nix build .#template-stable .#template-impermanence-stable --no-link
nix build .#toplevel --no-link
```

After regeneration, check the local gem versions in the package Gemfiles,
locks and gemsets against the source gemspecs. Look for stale pins and
unintended changes to external dependencies.

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
3. Generated packaged gem update from `make -B gems`.
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
