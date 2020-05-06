# osctl-exportfs 8                2020-05-06                             19.03.0

## NAME
`osctl-exportfs` - manage dedicated NFS servers for filesystem exports

## SYNOPSIS
`osctl-exportfs` [*global options*] *command* [*command options*] [*arguments...*]

## DESCRIPTION
`osctl-exportfs` manages dedicated NFS servers run in lightweight containers
for that purpose. Each NFS server runs in its own network namespace, which is
useful for accounting and ensuring quality of service. Each NFS server also has
a custom set of exported filesystems.

`osctl-exportfs` utility can only be used in conjuction with the `osctl-exportfs`
service, which has to be enabled in system configuration using option
`osctl.exportfs.enable`, see vpsadminos-configuration.nix(5). The created NFS
servers are not persistent. The servers and their configuration is lost when
the host machine is rebooted.

Each NFS server lives in its own privileged container composed of mount, network,
UTS and PID namespace, but sharing the host's `/nix/store`. Servers can be
started either interactively using command `server spawn` or put into `runit`
supervision tree using command `server start`. Servers monitored by `runit` are
automatically restarted in case they inadvertedly stop.

## COMMANDS
`server ls` [*options*]
  List configured NFS servers and their state.

    `-H`, `--hide-header`
      Do not show header, useful for scripts.

    `-L`, `--list`
      List available parameters and exit.
    
    `-o`, `--output` *parameters*
      Select parameters to output, comma separated.

    `-s`, `--sort` *parameters*
      Sort output by parameters, comma separated.

`server new` [*options*] *name*
  Add a new NFS server identified by *name*.

    `-a`, `--address` *address*
      The server will be listening on *address* if provided. It is saved into the
      configuration file for later use with `server spawn` and `server start`.
      *address* has to be an IPv4 address without prefix.

   `--netif` *netif*
     Name of the server's network interface on the host system.
     Defaults to `nfs-<server>`.

   `--nfsd-port` *port*
     Configure port for rpc.nfsd, useful if server is behind firewall.

   `--nfsd-nproc` *nproc*
     Specify the number of NFS server threads. By default, eight threads
     are started. However, for optimum performance several threads should
     be used.

   `--[no-]nfsd-tcp`
     Instruct the kernel nfs server to open and listen on a TCP socket.

   `--[no-]nfsd-udp`
     Instruct the kernel nfs server to open and listen on a UDP socket.

   `--nfs-versions` *versions*
     Allow only selected NFS versions. Possible values are: `2`, `3`, `4`,
     `4.0`, `4.1` and `4.2` separated by commas.

   `--nfsd-syslog`
     By default, rpc.nfsd logs error messages (and debug messages, if
     enabled) to stderr. This option makes rpc.nfsd log these messages to
     syslog instead. Note that errors encountered during option processing
     will still be logged to stderr regardless of this option.

   `--mountd-port` *port*
     Use fixed port for rpc.mountd, useful if server is behind firewall.

   `--lockd-port` *port*
     Use a fixed port for the NFS lock manager kernel module (`lockd/nlockmgr`).
     This is useful if the NFS server is behind a firewall.

   `--statd-port` *port*
     Use a fixed port for `rpc.statd`. This is useful if the NFS server is
     behind a firewall.

`server del` *name*
  Delete configured NFS server identified by *name*.

`server set` *options* *name*
  Configure server options. Changes are saved to the server's configuration file.
  If the server is running, changes will take effect when it is restarted.

    `-a`, `--address` *address*
      The server will be listening on *address* if provided. It is saved into the
      configuration file for later use with `server spawn` and `server start`.
      *address* has to be an IPv4 address without prefix.

   `--netif` *netif*
     Name of the server's network interface on the host system.
     Defaults to `nfs-<server>`.

   `--nfsd-port` *port*
     Configure port for rpc.nfsd, useful if server is behind firewall.

   `--nfsd-nproc` *nproc*
     Specify the number of NFS server threads. By default, eight threads
     are started. However, for optimum performance several threads should
     be used.

   `--[no-]nfsd-tcp`
     Instruct the kernel nfs server to open and listen on a TCP socket.

   `--[no-]nfsd-udp`
     Instruct the kernel nfs server to open and listen on a UDP socket.

   `--nfs-versions` *versions*
     Allow only selected NFS versions. Possible values are: `2`, `3`, `4`,
     `4.0`, `4.1` and `4.2` separated by commas.

   `--nfsd-syslog`
     By default, rpc.nfsd logs error messages (and debug messages, if
     enabled) to stderr. This option makes rpc.nfsd log these messages to
     syslog instead. Note that errors encountered during option processing
     will still be logged to stderr regardless of this option.

   `--mountd-port` *port*
     Use fixed port for rpc.mountd, useful if server is behind firewall.

   `--lockd-port` *port*
     Use a fixed port for the NFS lock manager kernel module (`lockd/nlockmgr`).
     This is useful if the NFS server is behind a firewall.

   `--statd-port` *port*
     Use a fixed port for `rpc.statd`. This is useful if the NFS server is
     behind a firewall.

`server spawn` [*options*] *name*
  Start NFS server *name* and export its filesystems.

  The server will run in the foreground, it can be stopped by sending the
  process `SIGINT` or `SIGTERM` signal.

`server start` [*options*] *name*
  Start NFS server *name*, but put in a `runit` supervision tree. A `runsv`
  service is created in `/run/osctl/exportfs/runsvdir`, which is picked up
  and started by `runsvdir` running as part of `osctl-exportfs` service.

`server stop` *name*
  Remove the service for NFS server *name* from `runit` supervision tree and
  stop it.

`server restart` [*options*] *name*
  Restart NFS server *name*, which has to be running in a `runit` supervision
  tree.

`export ls` [*server*]
  List all exports or exports configured on *server*.

`export add` *options* *server*
  Export directory using NFS server *server*.

    `--directory` *dir*
      Directory from the host namespace to export. Required.

    `--as` *dir*
      Change the path the directory will be exported as. Optional.

    `--host` *host*
      Which hosts will be allowed to mount the export. Required.

    `--options` *options*
      Optional NFS export options.

`export del` *options* *server*
  Remove export from NFS server *server* with matching *dir* and *host*.
    
    `--as` *dir*
      Exported directory.
    
    `--host` *host*
      Hosts allowed to mount the exported directory.

## FILES
All configured NFS servers reside in `/run/osctl/exportfs`, which is initialized
by the `osctl-exportfs` service:

```
/run/osctl/exportfs
├── rootfs/
├── runsvdir/
└── servers/
```

Directory `rootfs/` is used to construct a new root filesystem for the server
container and is always empty on the host. Directory `runsvdir/` is monitored by
the `runsvdir` program from `runit`, i.e. services for servers started using
`server start` are put into this directory. Directory `servers/` contains
a subdirectory per NFS server, each with its own configuration.

## Server directory
Each server directory has the following structure:

```
<server name>
├── runsv/
├── shared/
├── state/
├── config.yml
├── exports
├── lock
└── [pid]
```

Directory `runsv/` is the service generated by command `server start`. It is
linked to `/run/osctl/exportfs/runsvdir` as long as the server should be running.

Directory `shared/` is used to propagate new mounts from the host to the NFS
container in order to add new exports.

NFS server state, normally found in `/var/lib/nfs` is stored in directory
`state/`.

`config.yml` contains server configuration, including exports. It is used by
`osctl-exportfs` to generate `exports`, which is then read by exportfs(8) to
actually configure the containerized NFS server.

File `lock` is used for synchronization. If the server is running, the PID of
its init is stored in file `pid`.

## BUGS
Report bugs to https://github.com/vpsfreecz/vpsadminos/issues.

## ABOUT
`osctl-exportfs` is a part of [vpsAdminOS](https://github.com/vpsfreecz/vpsadminos).
