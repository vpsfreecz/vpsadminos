# Deployment
vpsAdminOS is a custom spin of NixOS and as such is not supported by NixOS
deployment tools such as [NixOps] or [morph], although it is not too hard
to [patch them](#patching).

vpsAdminOS can be built from its repository using `make`, which is calling
`nix-build` under the hood. Check the [Makefile] for more information. Another
approach is to use `os-rebuild`, an alternative to `nixos-rebuild`, from
an already installed system.

At vpsFree.cz, we use our own tool for deploying vpsAdminOS and NixOS called
[confctl].

## confctl
[confctl] is a Nix deployment tool similar to [NixOps], [morph], etc. See its
[homepage](https://github.com/vpsfreecz/confctl) for more information.

[vpsfree-cz-configuration] is a confctl configuration used at vpsFree.cz. It also
contains modules to build a PXE server to boot vpsAdminOS systems over network.

## Patching
If you'd like to deploy vpsAdminOS systems using [NixOps] or [morph], it is
not too hard to patch them. We used them before we moved to [confctl](#confctl).

The main difference between building NixOS and vpsAdminOS is that when building
NixOS, you import module `<nixpkgs/nixos/lib/eval-config.nix>`. To build
vpsAdminOS, you need to import `<vpsadminos/os/default.nix>`. Examples of the
necessary changes can be found at our deprecated forks that include vpsAdminOS
support:

 - [old NixOps fork](https://github.com/vpsfreecz/nixops)
 - [old morph fork](https://github.com/vpsfreecz/morph)

[NixOps]: https://github.com/NixOS/nixops
[morph]: https://github.com/DBCDK/morph
[Makefile]: https://github.com/vpsfreecz/vpsadminos/blob/staging/os/Makefile
[confctl]: https://github.com/vpsfreecz/confctl
[vpsfree-cz-configuration]: https://github.com/vpsfreecz/vpsfree-cz-configuration
