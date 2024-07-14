# Distribution support
*osctld* distribution support enables seamless network configuration,
configuration of hostname, DNS resolvers and changing user passwords from
the host.

Currently supported distributions within a container are:

 - Alpine
 - Arch
 - CentOS
 - Chimera
 - Debian
 - Devuan
 - Fedora
 - Gentoo
 - NixOS
 - openSUSE
 - Slackware
 - Ubuntu
 - Void

Unsupported distributions can be used without any restrictions, except that
*osctld* will be able to configure the network only on the host, containers will
have to be configured manually. Hostname configuration will function only
partially (at runtime, no persistent configuration). DNS resolvers and password
changing should work on most distributions.

## Implementation
Distribution support code is a part of *osctld*, it's programmed in Ruby,
see directory [osctld/lib/osctld/dist\_config][dist config dir].

[dist config dir]: https://github.com/vpsfreecz/vpsadminos/tree/staging/osctld/lib/osctld/dist_config
