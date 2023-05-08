# Building container images
vpsAdminOS comes with a tool for building, testing and deploying container
images called `osctl-image`. `osctl-image` itself doesn't know how to build
specific images, it has to be used together with build scripts. `osctl-image`
prepares environment for the build scripts to run, decides what should be built,
where it should be built and processes build results.

## Build scripts
A set of container image build scripts is a part of vpsAdminOS, you can find
them in vpsAdminOS repository in directory [image-scripts/]. The interface used
for communication between the build scripts and `osctl-image` is described
in man [osctl-image(8)].

The build scripts are called in three modes: configuration, build and test.
In configuration mode, the build scripts are called from the vpsAdminOS host
where osctl-image is run. `osctl-image` uses the configuration mode to learn
what images can be built, what environments the builds require and what tests
can be run.

Actual builds are run within build containers prepared by `osctl-image`.
Build containers are created simply from previously built images, where some
additional required packages can be installed. The build scripts declare what
build containers are needed and how to set them up.

In the build mode, the build scripts are supposed to prepare a root filesystem,
which is then packed into the container image by `osctl-image`. The build scripts
can use whatever dependencies their build containers have at their disposal.

Tests are run from the host, but using `nix-shell` so that the build scripts
can use whatever dependencies from nixpkgs they require. Each test is run
with a dedicated container, the script verifies if the container passes the test.

See man [osctl-image(8)] for more information.

## Workflow
`osctl-image` is a part of vpsAdminOS, so it has to be called from some
vpsAdminOS host. The build scripts have to be in the current working directory:

```shell
git clone https://github.com/vpsfreecz/vpsadminos
cd vpsadminos/image-scripts
```

List available images:
```shell
osctl-image ls
NAME                  DISTRIBUTION   VERSION               ARCH     VENDOR       VARIANT
ubuntu-16.04          ubuntu         16.04                 x86_64   vpsadminos   minimal
centos-6              centos         6                     x86_64   vpsadminos   minimal
gentoo                gentoo         20190607              x86_64   vpsadminos   minimal
alpine-3.9            alpine         3.9                   x86_64   vpsadminos   minimal
nixos-unstable        nixos          unstable-20190607     x86_64   vpsadminos   minimal
nixos-19.03           nixos          19.03                 x86_64   vpsadminos   minimal
opensuse-tumbleweed   opensuse       tumbleweed-20190607   x86_64   vpsadminos   minimal
devuan-2.0            devuan         2.0                   x86_64   vpsadminos   minimal
fedora-30             fedora         30                    x86_64   vpsadminos   minimal
fedora-29             fedora         29                    x86_64   vpsadminos   minimal
debian-8              debian         8                     x86_64   vpsadminos   minimal
alpine-3.8            alpine         3.8                   x86_64   vpsadminos   minimal
ubuntu-18.04          ubuntu         18.04                 x86_64   vpsadminos   minimal
centos-7              centos         7                     x86_64   vpsadminos   minimal
void-glibc            void           glibc-20190607        x86_64   vpsadminos   minimal
void-musl             void           musl-20190607         x86_64   vpsadminos   minimal
debian-9              debian         9                     x86_64   vpsadminos   minimal
arch                  arch           20190607              x86_64   vpsadminos   minimal
slackware-14.2        slackware      14.2                  x86_64   vpsadminos   minimal
opensuse-leap-15.1    opensuse       leap-15.1             x86_64   vpsadminos   minimal
```

To build an image, you need to give `osctl-image` a ZFS dataset for build
purposes. The dataset should not have any data nor subdatasets that you care
about. Build selected image with:

```shell
osctl-image build --build-dataset tank/image-builds alpine-3.9
```

Unless changed with option `--output-dir`, the resulting images will be stored
in directory `./output`.

Tests can be run with:

```shell
osctl-image test --build-dataset tank/image-builds alpine-3.9
```

If you wish to manually check the image, a container can be created as:

```shell
osctl-image instantiate --build-dataset tank/image-builds alpine-3.9
```

To deploy the image to a repository, use:

```shell
osctl-image deploy --build-dataset tank/image-builds alpine-3.9 /where/is/your/repository
```

See [repositories] for more information about how to manage container image
repositories.

Containers managed by `osctl-image` can be seen using `osctl-image ct ls`
and deleted with `osctl-image ct del`.

[image-scripts/]: https://github.com/vpsfreecz/vpsadminos/tree/staging/image-scripts
[osctl-image(8)]: https://man.vpsadminos.org/man8/osctl-image.8.html
[repositories]: repositories.md
