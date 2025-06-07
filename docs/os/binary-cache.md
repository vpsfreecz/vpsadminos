# Binary cache
vpsAdminOS has its own binary cache which contains builds of vpsAdminOS
with the current NixOS stable branch. Using it can save a lot of time building
the kernel.

```nix
{ config, ... }:
{
  nix.settings = {
    substituters = [ "https://cache.vpsadminos.org" ];
    trusted-public-keys = [ "cache.vpsadminos.org:wpIJlNZQIhS+0gFf1U3MC9sLZdLW3sh5qakOWGDoDrE=" ];

    # Enable fallback in case the binary cache is unreachable
    fallback = true;
    connect-timeout = 15;
  };
}
```
