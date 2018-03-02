# Resource management
A container's CPU and memory usage, IO throttling, network priorities
and access to devices is managed using CGroups. Number of processes or open
files can be set using process resource limits, as described in man
setrlimit(2).

## CGroup based limits
*osctld* has a concept of groups, where each group represents a CGroup in all
subsystems. There are always two groups: the *root* group and the *default*
group. The *root* group is the parent of all other groups, its path defaults to
`osctl`. Newly created containers are put into the *default* group, unless
configured otherwise. Groups can be nested and you can configure arbitrary
CGroup subsystem parameters for every group. Every container belongs to exactly
one group, i.e. the *default* group or any other. You can also configure CGroup
parameters of the containers themselves.

What this means is that you can place containers in groups and set *shared*
limits. On top of that, you can set limits on specific containers. For example,
when you set a limit of 10 GB memory on the *root* group, all containers will
be affected by this limit. At the same time, you can set a per-container limit
to 1 GB, which would give you ten 1 GB containers, or allow you to over-commit.

Groups are managed by `osctl group` commands:

```bash
osctl group ls
POOL   NAME      PATH      MEMORY   CPU_TIME 
tank   root      osctl     32.0M    16s
tank   default   default   32.0M    16s
```

You can notice that the path to the *default* group does not begin with `osctl`,
the *root* group. That is correct, the *root* group is prefixed automatically to
all other groups and is not mentioned explicitly.

CGroup parameters can be set as follows:

```bash
osctl group cgparams set root cpu.shares 768
osctl group cgparams set root memory.limit_in_bytes 10G
osctl group cgparams ls root
PARAMETER                VALUE
cpu.shares               768.0
memory.limit_in_bytes    10.0G

osctl group cgparams set default memory.limit_in_bytes 5G
osctl group cgparams ls default
PARAMETER                VALUE
memory.limit_in_bytes     5.0G
```

In this way, you can configure any available CGroup parameter.

Since the groups are nested, it is useful to see what parameters are set for
a particular group including all its parents, up to the *root* group. That's
what `-a`, `--all` switch is for:

```bash
osctl group cgparams ls -a default
GROUP     PARAMETER                VALUE
root      cpu.shares               768.0
root      memory.limit_in_bytes    10.0G
default   memory.limit_in_bytes     5.0G
```

Let's create a new group, create a new container within it and set some limits:

```
osctl group new --path my/custom/group mygroup01
osctl group cgparams set mygroup01 memory.limit_in_bytes 2G
```

The group's path can be nested and you're not limited to a path consisting
of existing groups, i.e. there is no group for path `my`, nor `my/custom`.
There could be, but it's not a requirement. Do not include path to the *root*
group, it will be prefixed automatically. Now, let's create a container
and place it in the new group:

```bash
osctl ct new \
             --user myuser01 \
             --group mygroup01 \
             --distribution ubuntu --version 16.04 \
             myct02
```

Container CGroup parameters are managed in the same way as for groups, the
subcommands are exactly the same:

```
osctl ct cgparams set myct02 memory.limit_in_bytes 512M
```

Let's see what we have configured:

```bash
osctl ct cgparams ls -a myct02
GROUP       PARAMETER                 VALUE
root        memory.limit_in_bytes     10.0G
root        cpu.shares                768.0
mygroup01   memory.limit_in_bytes      2.0G
-           memory.limit_in_bytes    512.0M
```

Before the container is started, parameters from all the groups listed above
will be set, top to bottom.

## Process resource limits
Resource limits can be set only on containers. For a list of available limits,
see man setrlimit(2). Limit names are expected in lower case and without
the `RLIMIT_` prefix. For example:

```bash
osctl ct prlimit set myct02 nproc 4096
osctl ct prlimit set myct02 nofile 1024
```

The commands above will limit the container to 4096 processes and 1024 open
files.
