# Configuration

vpsAdminOS uses Nix configuration language and re-uses
number of NixOS modules (e.g. user configuration).

Default and example configs are included in `os/configs/` directory.

  * `make qemu` uses `default.nix`
  * `make prod` uses `prod.nix`
  * `make iso-image` uses `iso.nix`

All of these configs include a `common.nix` file with configuration
common for all targets. `common.nix` also includes `local.nix` if present.
Use `local.nix` to set your `SSH` keys, root password and parameters for QEMU.
Use `local.nix.sample` as a starting point.

## Declarative containers

It is possible to built the `os` with images for containers to be imported and started on boot by `osctld`. For examples
see `configs/containers` directory. This functionality is experimental and mostly used for testing.

## Explicit configuration and dependencies

Most of the `make` targets are just a wrappers for `nix-build`. Is it possible
to build the `os` by specifying required arguments directly without relying on
`nixops` or setting correct `NIX_PATH`. Following example demonstrates how
to build the `os` directly without `make`.

```bash
cd os
nix-build \
 --arg configuration ./configs/default.nix \
 --arg vpsadmin "../../vpsadmin" \
 --arg nixpkgs "../../nixpkgs" \
 --cores 0
```

`configuration` can also be passed via environmental variable `VPSADMINOS_CONFIG`, so this is equivalent:
`VPSADMINOS_CONFIG` has to be an absolute path.

```bash
cd os
export VPSADMINOS_CONFIG=$(pwd)/configs/default.nix
nix-build \
 --arg vpsadmin "../../vpsadmin" \
 --arg nixpkgs "../../nixpkgs" \
 --cores 0
```
