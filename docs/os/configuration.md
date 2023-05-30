# Configuration

vpsAdminOS uses Nix configuration language. It reuses a number of NixOS modules
for system configuration and also adds some of its own. The full list of
supported options can be found in the
[OS reference documentation](https://ref.vpsadminos.org/os/options.html).

Default and example configs are included in `os/configs/` directory.

  * `make qemu` uses `qemu.nix`
  * `make iso-image` uses `iso.nix`

The simplest way to start with vpsAdminOS is to clone its repository and
put your configuration in `os/configs/local.nix`, which you can base on
`os/configs/local.nix.sample`. `local.nix` is imported with `make qemu` automatically
if it exists.

Another option is to put path to your config to environment variable
`VPSADMINOS_CONFIG`, e.g.:

```
export VPSADMINOS_CONFIG=/where/is/your/config.nix
make qemu
```

## Declarative containers

It is possible to built the `os` with images for containers to be imported and
started on boot by `osctld`. For examples see `configs/containers` directory.
This functionality is experimental and mostly used for testing.

## Explicit configuration and dependencies

Most of the `make` targets are just wrappers for `nix-build`. It is possible
to build the `os` by specifying required arguments directly without relying on
`nixops` or setting the correct `NIX_PATH`. The following example demonstrates
how to build the `os` directly without `make`.

```bash
cd os
nix-build \
 --arg configuration /where/is/your/config.nix \
 --arg nixpkgs "../../nixpkgs" \
 --cores 0
```

`configuration` can also be passed via environmental variable `VPSADMINOS_CONFIG`,
so this is equivalent:

```bash
cd os
export VPSADMINOS_CONFIG=/where/is/your/config.nix
nix-build \
 --arg nixpkgs "../../nixpkgs" \
 --cores 0
```

`VPSADMINOS_CONFIG` has to be an absolute path.
