# Deployment
vpsAdminOS is a custom spin of NixOS and as such is not supported by NixOS
deployment tools like [NixOps] or [morph], although it is not too hard
to [patch them](#patching).

vpsAdminOS can be built from its repository using `make`, which calls
`nix build` under the hood. Check the [Makefile] for more information. Another
approach is to use `vpsadminos-rebuild` from an already installed system with a
flake-based `/etc/vpsadminos` configuration.

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

The main difference between building NixOS and vpsAdminOS is the flake output
used for system configurations. vpsAdminOS systems are exposed as
`vpsadminosConfigurations.<name>` through `vpsadminos.lib.vpsadminosSystem`.
Examples of the older non-flake integration patches can be found at our
deprecated forks:

 - [old NixOps fork](https://github.com/vpsfreecz/nixops)
 - [old morph fork](https://github.com/vpsfreecz/morph)

[NixOps]: https://github.com/NixOS/nixops
[morph]: https://github.com/DBCDK/morph
[Makefile]: https://github.com/vpsfreecz/vpsadminos/blob/staging/os/Makefile
[confctl]: https://github.com/vpsfreecz/confctl
[vpsfree-cz-configuration]: https://github.com/vpsfreecz/vpsfree-cz-configuration
