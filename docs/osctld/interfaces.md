# Interfaces
*osctl* and *osctld* are general purpose tools meant for system administrators.
They're not the tools that can be given to end users to manage their containers.
*osctld* is designed in a way to make integration with information systems
with custom business logic as easy as possible.

## osctl
To simplify parsing, *osctl* has global option `-p`, `--parsable`, which is used
to get exact data, i.e. not formatted in a human readable form. Global option
`-j`, `--json` formats output in JSON.

Useful list options:

 - `-H` do not show header
 - `-o fields...` select what fields to print
 - `-L` print available fields

*osctl* also includes a Ruby client library [OsCtl::Client]. You can use this
class to connect to *osctld* and issue commands.

## Management socket
*osctl* interacts with *osctld* using a local socket at
`/run/osctl/osctld.sock`. The protocol is described in documentation of
[OsCtld::Generic::ClientHandler]. In short, the protocol is line-based, data
formatted in JSON. Client sends a command with parameters, *osctld* executes it
and reports success or failure.

For the list of commands, see *osctld* sources. This interface may change
between versions, you're encouraged to use `osctl` instead.

### Pool storage activity

The read-only `pool_storage_activity` command takes one `pool` name and returns
one bounded activity sample. Version `1` reports coverage `gc_trash_v1`: the
per-pool run-dataset garbage collector and trash-bin workers. The sample has a
daemon boot UUID, a UUID for the current pool import, and a daemon-local
monotonic generation. It also reports the pool state (`importing`, `active`,
`stopping`, or `absent`), pending and running counts for `run_gc`,
`trash_prune`, and `trash_move`, the registered run-dataset count, both worker
states, `unknown` and `overflow` flags, and any unknown reason codes. Counts
stop at 10,000; overflow remains unknown for the life of the daemon.

`idle: true` means only that this sample found an active pool, both workers
alive, no pending or running work in this coverage, and no unknown reason.
It does not stop new work, prove that external ZFS commands have finished, or
authorize a storage repair. A missing command on an older daemon, a failed
request, an invalid response, or a changed boot UUID or generation must be
treated as unknown by a caller that compares samples. A pool reimport gets a
new instance UUID without resetting the daemon's generation.

## Events
One of the management commands is `event_subscribe`. Subscribed clients are
informed abour various events, such as management commands,
adding/removing/changing of users, groups and containers. `osctl -j monitor`
will print all events in JSON to standard output.

[OsCtl::Client]: https://ref.vpsadminos.org/osctl/OsCtl/Client.html
[OsCtld::Generic::ClientHandler]: https://ref.vpsadminos.org/osctld/OsCtld/Generic/ClientHandler.html
