# NixOS guests

NixOS guests need a compatibility module to boot and use networking supplied by
the vpsAdminOS host. Import it from the vpsAdminOS flake, or download the
self-contained module for your guest's release.

## Stable flake imports

Use `vpsadminos.nixosModules.containerStable` in the guest's module list:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    vpsadminos.url = "github:vpsfreecz/vpsadminos";
  };

  outputs = { nixpkgs, vpsadminos, ... }: {
    nixosConfigurations.vps = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        vpsadminos.nixosModules.containerStable
        ./configuration.nix
      ];
    };
  };
}
```

The selector uses the guest's nixpkgs release. The import can stay unchanged
when you upgrade the guest to another known stable release. `nixosModules.container` is an equivalent alias.

Selection is independent of `system.stateVersion`. Keep that setting at the
value appropriate for your installation; changing the guest's nixpkgs release
does not require changing stateVersion. The vpsAdminOS flake's own nixpkgs input
also does not determine which guest module is selected.

The release map contains `22.11`, `23.05`, `23.11`, `24.05`,
`24.11`, `25.05`, `25.11` and `26.05`. These modules remain available for
compatibility; their availability does not imply upstream security support.
You can select a release explicitly with a literal key:

```nix
vpsadminos.nixosModules.containers."26.05"
```

Or use the guest nixpkgs input's release without converting dots to underscores:

```nix
vpsadminos.nixosModules.containers.${nixpkgs.lib.trivial.release}
```

Each leaf is an importable module. `nixosModules.containers` is a lookup map and
must not itself be imported. Consumers that enumerate `nixosModules` must handle
this map separately.

An unknown release fails during evaluation. The selector's error names the
release, lists known releases and advises updating the vpsAdminOS input or
selecting the explicit unstable module. There is no fallback to unstable.
Direct lookup of a missing grouped key produces Nix's missing-attribute error.

## Unstable guests

Use `vpsadminos.nixosModules.containerUnstable` with nixpkgs unstable. The stable
selector uses the release number and cannot identify the source branch. If an
unstable snapshot reports a known stable release number, the stable selector
chooses that release's module. A version suffix such as `pre-git` also does not
reliably identify unstable.

## Existing imports and generated configurations

Existing underscore exports such as `nixosModules.container_24_11` keep their
exact release-specific behavior. The legacy exports
`nixosConfigurations.container` and `nixosConfigurations.containerStable` keep
using the raw latest-stable module, independently of the guest release.
`nixosConfigurations.containerUnstable` remains the explicit unstable module.
These legacy values are modules, rather than evaluated NixOS systems.

Stable image templates generate `nixosModules.containerStable`; unstable
templates generate `nixosModules.containerUnstable`. The ordinary and
impermanence variants use the same choice. First boot copies configuration files
only when they are absent, so an image update does not rewrite an existing
guest configuration.

The grouped exports and release-aware selectors require a vpsAdminOS revision
that provides this interface. Earlier revisions accept `containerStable` but
use their latest-stable module. Keep the generated lockfile, or lock an
appropriate published revision before relying on the selector.

## Standalone module

For a configuration without the flake import, download the versioned stable file
matching the guest's release, for example:

```sh
curl -o /etc/nixos/vpsadminos.nix \
  https://raw.githubusercontent.com/vpsfreecz/vpsadminos/staging/os/lib/nixos-container/stable/vpsadminos-26.05.nix
```

Import `./vpsadminos.nix` from the guest configuration. The raw versioned files,
`stable/vpsadminos.nix` (latest stable), and `unstable/vpsadminos.nix` are each
self-contained; no companion files are required. A downloaded file cannot
automatically select another release. The root
`os/lib/nixos-container/vpsadminos.nix` is a guard and is not the download target.

## Changing an existing guest import

Update the vpsAdminOS input to a revision with this interface, change the import,
and evaluate the configuration with the existing guest nixpkgs pin and
stateVersion before activation. Compare the result with the matching explicit
release module. Guests adopt independently when rebuilt; no coordinated update
of hosts or running nodes is required.

Keep the prior lockfile and NixOS generations for recovery. Reverting to a
vpsAdminOS revision without grouped exports also requires reverting grouped
imports. To restore former latest-stable behavior for a modern generic import,
restore the prior vpsAdminOS pin or choose an appropriate explicit module.
The import change introduces no persisted state or data conversion. A separate
NixOS release upgrade retains that release's normal rollback constraints.
