# Auto starting
Selected containers can be chosen to be started when *osctld* imports its pool.
Since *osctld* is automatically importing all active pools when it starts as the
host system boots up, it effectively starts those containers together with
the host node.

Containers are not started automatically by default, it must be explicitly
enabled using `osctl ct set autostart` per container:

```shell
osctl ct set autostart myct01
```

Its settings can then be verified e.g. with `osctl ct show`:

```shell
osctl ct show -o autostart,autostart_priority,autostart_delay myct01
          AUTOSTART:  true
 AUTOSTART_PRIORITY:  10
    AUTOSTART_DELAY:  5
```

`AUTOSTART_PRIORITY` determines the order in which containers are started.
`0` is the highest priority, greater numbers have lower priority. Containers
with higher priority are started first. `AUTOSTART_DELAY` signifies how many
seconds should *osctld* wait before starting another container, thus giving
the container time to start, or at least dampen the load. Autostart priority
defaults to `10` and delay to `5` seconds.

Both parameters can be changed:

```shell
osctl ct set autostart --priority 5 --delay 10 myct01

osctl ct show -o autostart,autostart_priority,autostart_delay myct01
          AUTOSTART:  true
 AUTOSTART_PRIORITY:  5
    AUTOSTART_DELAY:  10
```

The container was given higher priority and its start time prolonged to
10 seconds.

## Auto start queue
When the auto start process is in progress, it is possible to monitor it.
`osctl ct pool autostart queue` will list the queue of containers that are about
to be started.

```shell
osctl pool autostart queue tank
ID       PRIORITY   DELAY 
myct02   10         5     
myct03   10         5     
myct04   10         5     
myct05   10         5     
myct06   10         5
```

The current auto start process can be aborted using `osctl pool autostart cancel`:

```shell
osctl ct autostart cancel tank

osctl pool autostart queue tank
# the queue is empty
```

The auto start process can be manually started using `osctl pool autostart trigger`:

```shell
osctl pool autostart trigger tank

osctl pool autostart queue tank
ID       PRIORITY   DELAY 
myct02   10         5     
myct03   10         5     
myct04   10         5     
myct05   10         5     
myct06   10         5
```

# Disabling auto starting
To persistently prevent a container from being started automatically on pool
import, you can use `osctl ct unset autostart`:

```shell
osctl ct unset autostart myct01

osctl ct show -o autostart,autostart_priority,autostart_delay myct01
          AUTOSTART:  -
 AUTOSTART_PRIORITY:  -
    AUTOSTART_DELAY:  -
```

It is also possible to temporarily skip the auto start process when importing
a pool into *osctld*:

```shell
osctl pool import --no-autostart tank
```

The auto start process can be later trigger manually using
`osctl pool autostart trigger`.
