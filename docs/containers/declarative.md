# Declarative containers
Declarative containers are defined in Nix configuration along with your
vpsAdminOS nodes, like [NixOS containers] are. Declarative containers
are not created and configured imperatively using *osctl* in the terminal.
When you wish to create or change a declarative container, you edit your Nix
configuration files and [redeploy][deployment] or [update][updates] the host
node. Once deployed, declarative containers can be controlled along with your
imperative containers using *osctl*.

Naturally, NixOS works best for declarative containers, as all such containers
can be build and deployed together with the host node. However, it is also
possible to declaratively create containers with any other distribution
using [templates]. These containers are not build together with the host node,
but are created when the host node boots or is redeployed.

## Example configuration
Declarative configuration mirrors the imperative approach. You can define and
configure users, groups and containers. Configurations are bound to specific
ZFS pools. First make sure that you have [defined some ZFS pool][pools], this
document uses pool `tank`. The following example configuration defines one user
and a container:

```nix
osctl.pools.tank = {
  # This is equivalent to
  #   osctl --pool tank user new --map 0:666000:65536 sample
  users.sample = let mapping = [ "0:666000:65536" ]; in {
    uidMap = mapping;
    gidMap = mapping;
  };

  containers.myct01 = {
    # Equivalent to
    #   osctl --pool tank ct new --user sample
    user = "sample";

    # Nix configuration
    config =
      { config, pkgs, ... }:
      {
        # Here you'd put the container's configuration
      };

    # Equivalent to
    #   osctl ct netif new bridge --link lxcbr0 tank:myct01 eth0
    interfaces = [
      {
        name = "eth0";
        type = "bridge";
        link = "lxcbr0";
      }
    ];

    # Start the container when the host boots, equivalent to
    #   osctl ct set autostart tank:myct01
    autostart.enable = true;
  };
};
```

When you deploy the vpsAdminOS node with this configuration, container
`myct01` will be created on pool `tank`.

For more examples, see directory [os/configs/containers][examples] in vpsAdminOS
source repository.

## Template-based containers
To create containers with distributions other than NixOS, you can use the
distribution templates vpsAdminOS provides:

```nix
osctl.pools.tank = {
  containers.myct02 = {
    user = "sample";

    distribution = "ubuntu";
    version = "18.04";

    interfaces = [
      {
        name = "eth0";
        type = "bridge";
        link = "lxcbr0";
      }
    ];

    autostart.enable = true;
  };
};
```

The container above will be created from a template downloaded from the default
repository provided by vpsAdminOS. Containers can also be created from custom
template archives:

```nix
osctl.pools.tank = {
  containers.myct02 = {
    ...
    distribution = "ubuntu";
    version = "18.04";

    # For templates stored as gzipped tar archives
    template = { type = "archive"; path = ./where/is/your/template.tar.gz };

    # For templates stored as gzipped ZFS streams
    template = { type = "stream"; path = ./where/is/your/template.dat.gz };
    ...
  };
};
```

If the path to template is relative, it has to be available on the system when
you're building the host node. It will be copied to Nix store and deployed to
the host node. If the path is absolute and given as a string, you have to
make the file available on the host node yourself.

Containers created in this way are configured from the outside, such as CGroup
limits, but not from the inside. They contain only what was in the used template.
For example, templates from vpsAdminOS repository contain only minimal system
and the user is expected to install what he needs. Initial configuration can
be done using the `post-create` hook:

```nix
osctl.pools.tank = {
  containers.myct02 = {
    ...
    distribution = "ubuntu";
    version = "18.04";

    # This is needed for the container to be started before the post-create hook
    # is called
    autostart.enable = true;

    hooks.post-create =
      let
        exec = "${pkgs.osctl}/bin/osctl ct exec $OSCTL_POOL_NAME:$OSCTL_CT_ID";
      in pkgs.writeScript "myct02-post-create" ''
        #!/bin/sh
        ${exec} apt-get update
        ${exec} apt-get upgrade -y
        ${exec} apt-get install -y nginx
        ...
      '';
    ...
  };
};
```

If `autostart.enable = true`, then the container will be started when the
*post-create* hook is called. This lets you to use *osctl ct exec* to execute
arbitrary commands within the container, such as install software or run some
more powerful configuration management like Ansible, Salt or Puppet.

## Inner workings
All declared users, groups and containers are represented by runit services.
For users, there is service `users-<pool>`, for groups there is `groups-<pool>`,
for template repositories `repositories-<pool>` and for containers there are
services named as `ct-<pool>-<id>`. For the example above, the names would be
`users-tank`, `groups-tank`, `repositories-tank` and `ct-tank-myct01`.
These services create and modify declared users, groups, repositories and
containers. Their logs can be found either in syslog or in an appropriate folder
in `/var/log`.

## Removing undeclared entities
If you declare a container, deploy, then remove it from configuration
and redeploy the system, the created container will be left alone.
This is the default behaviour to prevent accidental data loss. Destroying
of undeclared containers is controlled by option
`osctl.pools.<pool>.destroyUndeclared`:

```nix
osctl.pools.tank = {
  ...
  destroyUndeclared = true/false;
  ...
};
```

To remove all imperatively created users, groups, repositories and containers,
you can set option `osctl.pools.<pool>.pure`. You can use it if your pool should
contain **only** declarative containers.

```nix
osctl.pools.tank = {
  ...
  pure = true/false;
  ...
};
```

`destroyUndeclared` and `pure` control all users, groups and containers on
the specified pool. Undeclared and imperatively created entities are cleared
either by running `gc-sweep-<pool>` or by runit services called `gc-<pool>`,
e.g. `gc-tank`. Presence of the runit services is determined by option
`osctl.pools.<pool>.destroyMethod`, which is set to `manual` by default --
the garbage collector has to be run manually.

## Declarative devices
In order to grant access to devices declaratively, you need to understand
the [devices access trees][devices]. To give a container access to a device,
it needs to be allowed in all parent groups, starting from the root group.

The simplest approach is to allow access to a device in the root group and let
all other groups and containers inherit it. The root group, however, is
a special kind of group that grants access to a basic set of devices that every
container needs. Thus, when you're configuring devices of the root group, you
must also include the standard devices. List of these devices is stored in
`<vpsadminos/os/modules/osctl/standard-devices.nix>`. For example, to allow
access to `/dev/fuse` for all containers, you could do:

```nix
osctl.pools.tank = {
  groups."/" = {
    devices = (import <vpsadminos/os/modules/osctl/standard-devices.nix>) ++ [
      {
        name = "/dev/fuse";
        type = "char";
        major = "229";
        minor = "10";
        mode = "rwm";
      }
    ];
  };
}
```

To give access only to a selected group, you'd have to prevent other groups
from inheriting the device by setting `provide = false`:

```nix
osctl.pools.tank = {
  groups."/" = {
    devices = (import <vpsadminos/os/modules/osctl/standard-devices.nix>) ++ [
      {
        name = "/dev/fuse";
        type = "char";
        major = "229";
        minor = "10";
        mode = "rwm";
        provide = false;  # Do not let child groups to inherit this device
      }
    ];
  };

  groups."/with-fuse" = {
    devices = [
      {
        name = "/dev/fuse";
        type = "char";
        major = "229";
        minor = "10";
        mode = "rwm";
      }
    ];
  };
}
```

Now, only containers in group `/with-fuse` will have access to the device.

## Script hooks
All user hook scripts as supported by *osctl* can also be defined declaratively,
for example:

```nix
osctl.pools.tank = {
  containers.myct01 = {
    ...
    hooks.post-start = pkgs.writeScript "myct01-post-start" ''
      #!/bin/sh
      echo "Called after the container is started"
    '';
    ...
  };
};
```

See [man osctl(8)][man osctl] for a list of all hooks and available environment
variables.

In addition to these *osctl* hooks, declarative containers have three more hooks:
*pre-create*, *on-create* and *post-create*. *pre-create* is called before
the container is created and can control whether it should be created or not.
*on-create* is called after the container was created, but before it is started.
*post-create* is called when the container was started. These script hooks can
be used to perform one-time tasks when creating the container.

```nix
osctl.pools.tank = {
  containers.myct01 = {
    ...
    hooks.pre-create = pkgs.writeScript "myct01-pre-create" ''
      #!/bin/sh

      exit 0 # to create the container
      exit 1 # to stop and retry
      exit 2 # to abort creation
    '';

    hooks.on-create = pkgs.writeScript "myct01-on-create" ''
      #!/bin/sh
      echo "Called when the container is created, but when it's not running yet"
    '';

    hooks.post-create = pkgs.writeScript "myct01-post-create" ''
      #!/bin/sh
      echo "Called the first time the container has started"
    '';
    ...
  };
};
```

[NixOS containers]: https://nixos.org/nixos/manual/index.html#sec-declarative-containers
[deployment]: ../os/deployment.md
[updates]: ../os/updates.md
[templates]: ./templates.md
[pools]: ../os/pools.md
[examples]: https://github.com/vpsfreecz/vpsadminos/tree/master/os/configs/containers
[devices]: ./devices.md
[man osctl]: https://man.vpsadminos.org/osctl/man8/osctl.8.html#script-hooks
