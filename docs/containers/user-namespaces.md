# User namespaces
User namespaces are used to isolate containers from the host system and from
each other. See man user\_namespaces(7) for more information.

## ID ranges
In order to ensure that containers are running in separate user namespaces,
user/group IDs from the host used for mapping are managed using ID ranges.
An ID range is split into blocks of 65536 or more IDs and user namespaces
are being allocated from these blocks. *osctld* creates one default ID range
per pool with the following configuration:

```bash
osctl id-range ls
POOL   NAME      START_ID   LAST_ID      BLOCK_SIZE   BLOCK_COUNT   ALLOCATED   FREE
tank   default   1000000    4294918719   65536        65520         0          65520
```

This range starts from ID 1000000 and has 65520 blocks, i.e. 65520 unique maps
can be created. Blocks can be allocated as:

```bash
osctl id-range allocate --block-count 4 --owner myblocks default
 BLOCK_INDEX:  0
 BLOCK_COUNT:  4
       OWNER:  myblocks
    FIRST_ID:  1000000
     LAST_ID:  1262143
    ID_COUNT:  262144
```

The entire allocation table can be printed with:

```bash
osctl id-range table ls default
TYPE        BLOCK_INDEX   BLOCK_COUNT   OWNER      FIRST_ID   LAST_ID      ID_COUNT
allocated   0             4             myblocks   1000000    1262143      262144
free        4             65516         -          1262144    4294918719   4293656576
```

Allocated blocks can then be used to create custom user namespace maps. Blocks
from one range can be allocated only once, but multiple ID ranges can span over
the same IDs.

Blocks are usually allocated automatically when creating user namespace
mappings or containers, see below.

## User namespace maps
User namespace maps are created automatically with containers. Unless configured
otherwise, every container creates its own user namespace mapping allocated from
the default ID range. Let's see how it works:

```bash
# Create a container
osctl ct new --distribution alpine myct01

# Find out which user the container uses
osctl ct show -o user myct01
 USER:  myct01
```

`osctl ct new` created a new user with the same name. The mapping itself can be
read with:

```bash
osctl user map myct01
TYPE   NS_ID   HOST_ID   COUNT
uid    0       1000000   65536
gid    0       1000000   65536

```

When needed, user namespace mappings can also be created manually, even
independently from ID ranges. Mappings cannot be edited, the only way is to
delete it and create a new one with different configuration.

### Allocated user namespace mappings
The simplest way to create a new user namespace mapping is:

```bash
osctl user new myuser01
```

The mapping will be allocated from the default ID range. Option `--id-range`
can be used to specify which ID range to allocate from. When creating containers,
pass option `--user myuser01` to use this mapping.

### Using specific ID range allocations
Let's say two containers should share the same mapping and more than one block
is needed. First, allocate it:

```bash
osctl id-range allocate --block-count 10 default
 BLOCK_INDEX:  4
 BLOCK_COUNT:  10
       OWNER:  -
    FIRST_ID:  1262144
     LAST_ID:  1917503
    ID_COUNT:  655360
```

Now pass the block index to `user new`:

```bash
osctl user new --id-range-block-index 4 myuser02
```

*osctld* will create a default mapping spanning the entire ID range allocation:

```bash
osctl user map myuser02
TYPE   NS_ID   HOST_ID   COUNT
uid    0       1262144   655360
gid    0       1262144   655360
```

### Custom mappings from ID range allocations
UID/GID mapping can be customized:

```bash
osctl user new --id-range-block-index 4 --map 0:1262144:65536 myuser03
```

Option `--map` sets both user and group mappings, options `--uid-map`
and `--gid-map` can be used to have different mappings for user and group IDs.

### Custom mappings
User namespace mappings don't have to be allocated from ID ranges, but then
it's the administrator's responsibility to ensure proper isolation. Use
options `--map`, `--uid-map` or `--gid-map` to create custom mappings:

```bash
osctl user new --map 0:123000:65536 myuser04
```
