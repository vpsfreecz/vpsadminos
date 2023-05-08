# Container image repositories
Repositories are used to distribute container images to vpsAdminOS nodes over
HTTP. vpsAdminOS comes with its own repository at <https://images.vpsadminos.org>,
but you can manage and use your own repositories if needed.

# Creating a repository
vpsAdminOS comes with a tool for creating and maintaining image repositories
called *osctl-repo*. *osctl-repo* creates a directory structure according to the
[repository scheme](../specifications/image-repository.md). *osctl-repo* is
not building the images, it only accepts pre-built images and places them
into the repository, ready to be served to clients by your web server. See
[creating images](creating.md) to learn how to build container images.

*osctl-repo* is a part of vpsAdminOS, but it can be installed to other
distributions as well as a Ruby gem:

```shell
gem install --source https://rubygems.vpsfree.cz --prerelease osctl-repo libosctl
```

To create a repository, you have to prepare a directory that is served by a web
server. Let's put the repository in `/var/www/vpsadminos-repo`. Configure your
web server to serve this directory, then cd into it and initiate the repository:

```shell
cd /var/www/vpsadminos-repo
osctl-repo local init
```

Images can then be added using `osctl-repo local add`:

```shell
osctl-repo local add \
                     --archive debian-archive.tar \
                     --zfs debian-stream.tar \
                     vpsadminos minimal x86_64 debian 9
```

Option `--archive` adds container image where the root filesystem is stored
as a tar archive. Option `--zfs` adds image with the container's filesystems
as ZFS streams.

Note that before a repository can be used, there has to be a default *vendor*
and vendor *variant*. It can be set with:

```shell
# Set vendor `vpsadminos` as default
osctl-repo local default vpsadminos

# Set variant `minimal` of vendor `vpsadminos` as default
osctl-repo local default vpsadminos minimal
```

# Declarative repositories
vpsAdminOS has a Nix module which can be used to define repositories
declaratively. You define what images are supposed to be there, where and how
to build them, and how often to rebuild them.

```nix
# Datasets related to the repository
boot.zfs.pools.tank.datasets = {
  "image-repository/target" = {};
  "image-repository/cache" = {};
  "image-repository/logs" = {};
  "image-repository/builds" = {};
};

# Repository itself
services.osctl.image-repository.myrepo = rec {
  # Where should the repository be stored
  path = "/tank/image-repository/target";

  # Where to cache image builds
  cacheDir = "/tank/image-repository/cache";

  # Where should build log files be stored
  logDir = "/tank/image-repository/logs";

  # Path to build scripts
  buildScriptDir = "/path/to/build-scripts";

  # Dataset used to build images
  buildDataset = "tank/image-repository/builds";

  # At each run, rebuild all images even if they are cached
  rebuildAll = true;
  
  # crontab-like run configuration, i.e. run the build each Saturday
  buildInterval = "0 4 * * sat";

  # Commands executed after the repository was rebuild, e.g. to copy it to
  # system which will then serve it over HTTP
  postBuild = ''
    ${pkgs.rsync}/bin/rsync -av --delete "${path}/" root@web-server:/var/www/repository
  '';

  vendors.vpsadminos = { defaultVariant = "minimal"; };
  defaultVendor = "vpsadminos";

  # What images should be built and put into the repository
  #
  # The following is an example configuration which is used to build vpsAdminOS
  # images at https://images.vpsadminos.org. Image names correspond with build
  # scripts at https://github.com/vpsfreecz/vpsadminos/tree/staging/image-scripts
  images = {
    # Image name is constructed as `<distribution>-<version>`, i.e. `alpine-3.8`
    # and `alpine-3.9`
    alpine = {
      "3.8" = {};
      "3.9" = { tags = [ "latest" "stable" ]; };
    };

    # Arch doesn't have any versions. Since the image name isn't `arch-rolling`,
    # it is set explicitly to `arch`
    arch.rolling = { name = "arch"; tags = [ "latest" "stable" ]; };

    centos = {
      "6" = {};
      "7" = { tags = [ "latest" "stable" ]; };
    };

    debian = {
      "8" = {};
      "9" = { tags = [ "latest" "stable" ]; };
    };

    devuan = {
      "2.0" = { tags = [ "latest" "stable" ]; };
    };

    fedora = {
      "29" = {};
      "30" = { tags = [ "latest" "stable" ]; };
    };

    gentoo.rolling = { name = "gentoo"; tags = [ "latest" "stable" ]; };

    nixos = {
      "19.03" = { tags = [ "latest" "stable" ]; };
      "unstable" = {};
    };

    opensuse = {
      "leap" = { tags = [ "latest" "stable" ]; };
      "tumbleweed" = {};
    };

    slackware."14.2" = { tags = [ "latest" "stable" ]; };

    ubuntu = {
      "16.04" = {};
      "18.04" = { tags = [ "latest" "stable" ]; };
    };

    void = {
      "glibc" = { tags = [ "latest" "stable" ]; };
      "musl" = {};
    };
  };
};
```

The configuration above will generate script `build-image-repository-myrepo`.
You can review it and run at any time. It will also be run regularly by cron,
based on option `buildInterval`.

# Configure custom repositories
Container image repositories are specific to pools. Each pool has a default
repository and any number of custom repositories. Repositories can be managed
using `osctl repo` command family.

```shell
osctl repo ls
osctl repo add myrepo https://repo.domain.tld
osctl repo del myrepo
```

Note that repositories are configured per-pool. When no pool is specified,
the default pool is configured. For example, to add repository to a non-default
pool, you could use:

```shell
osctl --pool mypool repo add myrepo  https://repo.domain.tld
```

# Accessing repository
*osctld* is accessing the repository on its own, so you don't have to read this
section unless you wish to understand how it works.

*osctl-repo* is also used to access repositories, i.e. to download images
from remote repositories and optionally cache them in a local directory.
All client commands work with remote repositories, so you always have to provide
the repository's URL as an argument.

To list available images, use command `remote ls`:

```shell
osctl-repo remote ls https://repo.domain.tld
```

Images can be downloaded using command `remote get path` and `remote get stream`.
`remote get path` will fetch the image and write its path to standard output.
`remote get stream` will write the image's contents to standard output.

If option `--cache <writable directory>` is provided, the image will be
saved in the cache directory. Subsequent calls of `remote get path|stream` with
the same cache directory will use the local version, unless the repository has
a newer version.

```shell
osctl-repo remote get path https://repo.domain.tld \
                           vpsadminos minimal x86_64 debian 9 zfs
```

If you only wish to cache the selected image, use `remote fetch`:

```shell
osctl-repo remote fetch --cache /var/vpsadminos-repo-cache \
                        https://repo.domain.tld \
                        vpsadminos minimal x86_64 debian 9 zfs
```
