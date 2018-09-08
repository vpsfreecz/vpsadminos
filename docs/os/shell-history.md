# Shell history
If vpsAdminOS is used as a live system, you'll find that root's shell
history is lost after every reboot. There are several ways to store the
history persistently.

## Saving history on ZFS pools
The most straightforward way is to change the shells's `$HISTFILE` to
a persistent location:

```nix
programs.bash.root.historyFile = "/tank/.bash_history";
```

This approach, however, is not recommended. Should the pool become suspended
or any other ZFS error occur, the pool may become inaccessible. When the shell
would attempt to access the history file, it may get stuck in an uninterruptible
state, preventing you from logging in.

To connect to such a machine, you'd have to tell the shell to skip loading its
configuration files, including the file where the custom `$HISTFILE` is set.

```bash
ssh -t vpsadminos /usr/bin/env bash --norc --noprofile
```

## Mirroring history
vpsAdminOS makes it easy to mirror shell history on one or more ZFS pools,
where it can be stored persistently. On boot, the history is restored from
one of the pools.

To save history on pool `tank`, set:

```nix
programs.bash.root.historyPools = [ "tank" ];
```

For every pool that the shell history is mirrored to, a runit service
`histfile-<pool>` is generated. The service monitors
`programs.bash.root.historyFile` for changes and mirrors it on the pool.

In case the pool becomes inaccessible, the service will get stuck and mirroring
will stop, but you will be able to login without any problems.
