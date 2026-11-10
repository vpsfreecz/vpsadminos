# Container image repositories

Repositories provide container images to `osctl` and `osctld` over HTTP.
The default repository is <https://images.vpsadminos.org>. You can maintain a
custom repository with its own name and selection of images.

A static web server such as nginx can serve the native repository format.
`osctl-repo-server` is an optional alternative with controlled uploads and
publication, sealed build catalogs, and a dashboard for repository usage and
contents. The native image builder and its configuration work with either choice.

# Creating a repository

`osctl-repo` maintains the directory structure described by the
[repository scheme](../specifications/image-repository.md). It accepts prebuilt
images; see [creating images](creating.md) for the build process. The command is
available on vpsAdminOS. For maintenance from a checkout, enter its environment:

```shell
nix develop .#vpsadminos
osctl-repo --help
```

Initialize a repository directory and add files from an image build:

```shell
mkdir -p /var/www/myrepo
cd /var/www/myrepo
osctl-repo local init
osctl-repo local add --archive /path/to/arch-archive.tar \
  --stream /path/to/arch-stream.tar \
  myrepo minimal x86_64 arch rolling
osctl-repo local default myrepo
osctl-repo local default myrepo minimal
```

`--archive` supplies a root filesystem tar archive; `--stream` supplies ZFS
streams. Supply the formats built for the image. Set both the default vendor
and its default variant before offering the repository to clients.

# Declarative repositories

The `services.osctl.image-repository` module accepts any repository name. This
example builds the rolling Arch image from a local vpsAdminOS checkout. Replace
the pool and checkout paths with your own. Run the builder on a host with the
required container and image-build privileges.

```nix
{ ... }:
{
  boot.zfs.pools.tank.datasets = {
    "image-repository/target" = { };
    "image-repository/cache" = { };
    "image-repository/logs" = { };
    "image-repository/builds" = { };
  };

  services.osctl.image-repository.myrepo = {
    path = "/tank/image-repository/target";
    cacheDir = "/tank/image-repository/cache";
    logDir = "/tank/image-repository/logs";
    buildScriptDir = "/path/to/vpsadminos/image-scripts";
    buildDataset = "tank/image-repository/builds";

    defaultVendor = "myrepo";
    vendors.myrepo.defaultVariant = "minimal";
    images.arch.rolling = {
      name = "arch";
      tags = [ "latest" "stable" ];
    };

    # Builds are manual unless the cron job is explicitly enabled.
    enableCronJob = false;
    buildInterval = "0 4 * * sat";
  };
}
```

After applying the host configuration, run the generated command as root:

```shell
build-image-repository-myrepo
```

Set `enableCronJob = true` to schedule it using `buildInterval`. Setting the
interval alone does not enable cron. `rebuildAll = true` forces fresh builds
instead of reusing cached images. Add `garbageCollection` rules to the named
repository to retain the desired number of matching old images; the default
empty rule list does not select any for collection.

The result is a native repository that can be served directly. A `postBuild`
hook can copy it to a static serving host with rsync. Keep that destination
separate from files adopted by the managed server below.

## Static nginx serving

Serve the directory containing `v1`, using a hostname routed to the web server.
For the declarative example, a standard nginx server block is:

```nginx
server {
    listen 80;
    server_name images.example.org;
    root /tank/image-repository/target;

    location / {
        try_files $uri $uri/ =404;
    }
}
```

Give nginx read/traverse access to the public tree. Configure HTTPS and its
certificate through the serving host's normal web-server configuration before
using an `https://` client URL. Static serving needs no `osctl-repo-server`
process, database or role sockets.

## Optional managed server

Install the package from a vpsAdminOS checkout:

```shell
nix profile install .#osctl-repo-server
```

Run it under a dedicated service account. The following foreground example uses
private directories in that account's home and a loopback HTTP listener. The
limits are illustrative, not production sizing recommendations: choose capacity,
headroom, upload size and retention for the actual repository.

```shell
umask 077
repo_service="$HOME/myrepo-service"
mkdir -p "$repo_service/state" "$repo_service/run" "$repo_service/logs"
osctl-repo-server serve \
  --root "$repo_service/state" --listen 127.0.0.1:8080 \
  --repository myrepo --instance myrepo-main \
  --display-name 'My repository' \
  --purpose 'Container images maintained for this installation.' \
  --producer-socket "$repo_service/run/producer.sock" \
  --publisher-socket "$repo_service/run/publisher.sock" \
  --admin-socket "$repo_service/run/admin.sock" \
  --max-bytes 10737418240 --reserve-bytes 1073741824 \
  --max-upload-bytes 1073741824 --max-runs 100 \
  --max-lease 24h --export-lease 168h \
  --access-log "$repo_service/logs/access.jsonl" \
  --access-log-max-bytes 10485760 --access-log-files 5 \
  --stats-days 365 --stats-max-rows 100000 --event-queue 4096
```

The stable `--repository` ID identifies catalogs and control requests.
`--display-name` and `--purpose` set plain text in the dashboard and API without
renaming stored state or native paths. They accept at most 128 and 512 Unicode
characters respectively, excluding control characters. An empty display name
uses the repository ID; an empty purpose omits the description.

The example keeps all sockets accessible only to the service account. For
separate operators, use `--producer-group`, `--publisher-group` and
`--admin-group` with corresponding OS groups and a traversable socket parent.
Keep state and logs private. Producers can upload but cannot publish; publishers
can select verified public images; administrators can import, export and reclaim.
Never expose these sockets through the public HTTP listener. See the
[server control and storage reference](../../osctl-repo-server/README.md) for
request contracts, publication/GC policy, lease expiry and reclamation.

### Initialize an empty catalog

Starting the server creates private storage but does not select a public catalog.
In a second shell under the same service account, create an empty native tree
with default aliases and import it. This requires `jq` and a fresh service root:

```shell
repo_service="$HOME/myrepo-service"
repo_tree="$HOME/myrepo-empty"
mkdir -p "$repo_tree/v1/myrepo/minimal"
printf '%s\n' '{"vendors":{"default":"myrepo","myrepo":"minimal"},"images":[]}' \
  > "$repo_tree/v1/INDEX.json"
ln -s myrepo "$repo_tree/v1/default"
ln -s minimal "$repo_tree/v1/myrepo/default"
jq -n --arg path "$repo_tree" '{
  request_id: "myrepo-empty-1", operation: "import-legacy", repository: "myrepo",
  params: {path: $path, generation: ""}
}' | osctl-repo-server ctl --socket "$repo_service/run/admin.sock"
```

A successful response has `ok: true` and a selected generation in
`result.generation`. The repository is now valid but contains no images. Populate
it through the producer/publisher protocol, or adopt a complete existing tree.

### Adopt an existing native repository

First stop and exclude every writer to the source tree: scheduled/manual native
builds, `osctl-repo local add/rm`, native GC and rsync. Retain a coherent backup.
The service account needs read access to every referenced file and directory.
For a fresh managed repository, import the complete built tree:

```shell
repo_service="$HOME/myrepo-service"
jq -n --arg path /tank/image-repository/target '{
  request_id: "myrepo-adopt-1", operation: "import-legacy", repository: "myrepo",
  params: {path: $path, generation: ""}
}' | osctl-repo-server ctl --socket "$repo_service/run/admin.sock"
```

Import validates `v1/INDEX.json`, payload hashes, and default and tag symlinks,
then adopts regular files in place. Keep those files immutable and available at
their original paths. Only the managed server may change adopted files. Native
builds must write to a separate staging repository. Configure publication
defaults, tags, and GC policy on the server explicitly; importing a tree does
not import the native builder's GC configuration.

Import replaces the whole public catalog, rather than adding missing images.
For an existing nonempty catalog, obtain its generation with an admin `status`
request and supply that exact value as `params.generation`; stale generations
conflict. Include every image/format and alias that must remain public. Reuse a
request ID only for an identical retry; use a new ID for a changed request.
Portable `import-generation` has the same replacement/CAS meaning.

```shell
printf '%s\n' '{"request_id":"myrepo-status-1","operation":"status","repository":"myrepo","params":{}}' \
  | osctl-repo-server ctl --socket "$repo_service/run/admin.sock"
```

### Serve and recover managed state

Point the HTTPS frontend at the loopback listener instead of the native tree:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_buffering off;
    proxy_request_buffering off;
}
```

The dashboard is at `/`; existing clients still use `/v1/INDEX.json` and the
native image paths. Only configure `--client-ip-header` and `--trusted-proxy`
when the trusted frontend replaces that header and direct untrusted backend
access is excluded; see [HTTP and logging](../../osctl-repo-server/HTTP.md).

Before returning to static serving/native writers, block managed writes and
export the **current** public catalog into a new directory:

```shell
jq -n --arg path "$HOME/myrepo-static-export" '{
  request_id: "myrepo-static-export-1", operation: "export-legacy",
  repository: "myrepo", params: {path: $path}
}' | osctl-repo-server ctl --socket "$HOME/myrepo-service/run/admin.sock"
```

Verify the exported index, aliases and payloads before selecting that tree for
static serving. Its top-level directory is private initially; grant the static
server read/traverse access deliberately. Do not resume from the stale original
rsync tree or write into files still referenced by the managed service. Preserve
managed state for recovery. For binary upgrades and coherent SQLite/payload
backups, follow [schema upgrade and recovery](../../osctl-repo-server/README.md#schema-1-to-2-upgrade-and-recovery);
changing a display name does not require a schema change.

# Configure custom repositories

Repositories are configured per pool. With no pool selector, `osctl` uses the
default pool:

```shell
osctl repo add myrepo https://images.example.org
osctl repo ls
osctl --pool mypool repo add myrepo https://images.example.org
```

Remove a pool's entry with `osctl repo del myrepo`. Both static and managed
serving use these same client commands.

# Accessing repository

`osctld` downloads images when requested through `osctl`. To inspect a
repository manually, use `osctl-repo`:

```shell
osctl-repo remote ls https://images.example.org
osctl-repo remote get path --cache /var/myrepo-cache https://images.example.org \
  myrepo minimal x86_64 arch rolling zfs
osctl-repo remote get stream https://images.example.org \
  myrepo minimal x86_64 arch rolling tar
osctl-repo remote fetch --cache /var/myrepo-cache https://images.example.org \
  myrepo minimal x86_64 arch rolling zfs
```

`get path` prints the downloaded file's path and requires a writable `--cache`
directory, as does `fetch`. `get stream` writes bytes to standard output and may
omit `--cache`. A newer remote version replaces the cached copy.
