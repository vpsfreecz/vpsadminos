# Runlevels
vpsAdminOS supports runlevels as suggested by
[runit documentation](http://smarden.org/runit/runlevels.html). There are
two runlevels built-in: *single* and *default*. *single* starts only gettys,
which is useful for maintenance. Runlevel *default* starts all services that
handle network configuration, importing of storage pools and starting
containers.

Every runit service belongs to one or more runlevels, you can create your own
runlevels by assigning services into it, see options under `runit.services`.

The default runlevel can be configured using option `runit.defaultRunlevel`.

## Switching runlevels
At runtime, runlevels can be switched using `runsvchdir`, e.g.:

```bash
runsvchdir single
runsvchdir default
```

It may take several seconds for runit to notice the change and start appropriate
services.

## Booting into a different runlevel
The default runlevel to boot can be changed using kernel arguments. You can
change these arguments in the bootloader if you have one, or generate config
for netboot. The recognized kernel argument is `runlevel=<name>`, e.g.
`runlevel=single`. `runlevel=single` can also be written as `1`.
