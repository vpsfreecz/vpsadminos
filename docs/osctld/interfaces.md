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

*osctl* also includes a Ruby client library `OsCtl::Client`. You can use this
class to connect to `*osctld* and issue commands.

## Management socket
*osctl* interacts with *osctld* using a local socket at
`/run/osctl/osctld.sock`. The protocol is described in documentation of
`OsCtld::Generic::ClientHandler`. In short, the protocol is line-based, data
formatted in JSON. Client sends a command with parameters, *osctld* executes it
and reports success or failure.

For the list of commands, see *osctld* sources. This interface may change
between versions, you're encouraged to use `osctl` instead.

## Events
One of the management commands is `event_subscribe`. Subscribed clients are
informed abour various events, such as management commands,
adding/removing/changing of users, groups and containers. `osctl -p monitor`
will print all events in JSON to standard output.
