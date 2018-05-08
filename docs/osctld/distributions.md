# Distribution support
*osctld* distribution support enables seamless network configuration,
configuration of hostname, DNS resolvers and changing user passwords from
the host.

Currently supported distributions within a container are:

 - Alpine
 - Arch
 - CentOS
 - Debian
 - Fedora
 - Gentoo
 - NixOS
 - Ubuntu

Unsupported distributions can be used without any restrictions, except that
*osctld* will be able to configure the network only on the host, containers will
have to be configured manually. Hostname configuration will function only
partially (at runtime, no persistent configuration). DNS resolvers and password
changing should work on most distributions.

## Implementation
Distribution support code is a part of *osctld*, it's programmed in Ruby,
see directory [osctld/lib/osctld/dist\_config][dist config dir].
*osctld* expects one class for each distribution, with [OsCtld::DistConfig::Base]
as its superclass. There is a method for each configurable part:

 - `set_hostname` to set hostname,
 - `network` to configure the network with all assigned network interfaces,
 - `add_netif` is called when a new interface is created,
 - `remove_netif` is called when an interface is removed,
 - `rename_netif` to change interface's name,
 - `dns_resolvers` to configure `/etc/resolv.conf`
 - `passwd` to set password for a system user.

*osctld* will call appropriate methods to configure the container at the correct
time in the container's life cycle. The methods are called from the host, as
the `root` user, as a part of the *osctld* process. The code can manipulate
the container from the outside, as it has access to the rootfs and can run
commands within the container, if it is running.

In case you're using a container with an unsupported distribution, class
[OsCtld::DistConfig::Unsupported] is used. Network and hostname configuration
log warnings, DNS resolvers and password changing should work everywhere.

## Adding support for a new distribution
Let's demonstrate adding support for Debian based distributions, as they are one
of the most known. This document will show a simplified implementation
and the full version can be seen in *osctld* sources.

Change to the `vpsadminos` repository and create file
`osctld/lib/osctld/dist_support/my_debian.rb`:

```ruby
module OsCtld
  class DistConfig::MyDebian < DistConfig::Base
    distribution :mydebian
  end
end
```

The file defines class `MyDebian` in module [OsCtld::DistConfig].
`distribution :mydebian` says that this class is for a distribution named
`mydebian`, i.e. this class will be used for containers whose distribution is
`mydebian`, which is determined at the time of container creation from
the template name. We're using `mydebian` instead of `debian`, because
the support for `debian` is already there.

[OsCtld::DistConfig::Base] implements generic support for DNS configuration (i.e.
`/etc/resolv.conf`) and user password manipulation via `chpasswd`, these should
work on most distributions. Hostname and network configuration can differ.

### Hostname configuration
On Debian, the hostname is stored in `/etc/hostname`. All we have to do is
generate the file and, if the container is running, apply the new hostname.

```ruby
# @param opts [Hash] options
# @option opts [String] original previous hostname
def set_hostname(opts)
  ### Generate /etc/hostname within the container
  # `ct` is an instance of `OsCtld::Container`
  path = File.join(ct.rootfs, 'etc', 'hostname')

  File.write(path, ct.hostname)

  ### Apply configuration at runtime
  if ct.running?
    # ct_syscmd() executes command within a container, like osctl ct exec
    ct_syscmd(ct, 'hostname -F /etc/hostname')
  end
end
```

And that's it. The full implementation is written a bit more safely
and in addition to `/etc/hostname` modifies also `/etc/hosts`, so that the
hostname will resolve into `127.0.0.1` and `::1`. You cannot overwrite
`/etc/hosts`, as the container might have its own entries there. The file has to
be patched to replace the old hostname with the new one, and this is where
the method's argument `opts[:original]` from the signature above comes in.

### Network configuration
Network in Debian based distributions is configured
in [/etc/network/interfaces](https://wiki.debian.org/NetworkConfiguration).
The simplest way is to generate the file every time the container starts or
the configuration changes. Network configuration is more complicated, because
a container can have multiple interfaces of different types, i.e. veth bridge
and routed veth.

For bridge, we'll use DHCP for IPv4, IPv6 will be unconfigured. For routed veth,
we have to configure IP address and routes for the interconnecting network.
We'll also assign any IP addresses configured via *osctl* to both bridged
and routed interfaces.

```ruby
def network(_opts)
  f = File.open(File.join(ct.rootfs, 'etc', 'network', 'interfaces'), 'w')

  # Start with `lo`
  f.puts(<<END
auto lo
iface lo inet loopback
END
  )

  # Configure all interfaces
  ct.netifs.each do |netif|
    case netif.type
    when :bridge
      f.puts(<<END
auto #{netif.name}
iface #{netif.name} inet dhcp
END
      )

    when :routed
      f.puts("auto #{netif.name}")
    
      # Define interface once for IPv4 and IPv6
      netif.active_ip_versions.each do |v|
        # Assign IP from the interconnecting network
        f.puts(<<END
iface #{netif.name} #{v == 4 ? 'inet' : 'inet6'} static
  address #{netif.via[v].ct_ip.to_s}
  netmask #{netif.via[v].ct_ip.netmask}
END
        )

        # Assign configured IP addresses
        netif.ips(v).each do |addr|
          f.puts(<<END
  up ip -#{v} addr add #{addr.to_string} dev #{netif.name}
  down ip -#{v} addr del #{addr.to_string} dev #{netif.name}
END
          )
        end

        # If there is at least one address, setup a default route with that
        # address being the source
        if netif.ips(v).any?
          f.puts(
            "up ip -#{v} route add default via #{netif.via[v].host_ip.to_s} "+
            "src #{netif.ips(v).first.to_s}"
          )
        end
      end
    end

    f.puts
  end

  f.close
end
```

*osctld* will call our `network()` method every time a container with
distribution `mydebian` starts. *osctld* will configure the host, and
the container's init script will configure the system by reading
`/etc/network/interfaces` we generated. Adding/removing IP addresses at runtime
is handled by *osctld* itself using `/sbin/ip`.

## Guidelines
*osctld* has methods for generating files from ERB templates, as you can see by
looking at existing distribution-support code, which utilizes templates instead
of mixing strings with code. Templates are stored in [osctld/templates/],
methods for using them are in module [OsCtld::Template].

When generating the network configuration, depending on the distribution,
the owner of the container should be able to add his own configuration. For
example, the included Debian configuration can be extended by creating
`/etc/network/interfaces.{head,tail}` or files in `/etc/network/interfaces.d/`.

[dist config dir]: https://github.com/vpsfreecz/vpsadminos/tree/master/osctld/lib/osctld/dist_config
[OsCtld::DistConfig::Base]: https://ref.vpsadminos.org/osctld/OsCtld/DistConfig/Base.html
[OsCtld::DistConfig::Unsupported]: https://ref.vpsadminos.org/osctld/OsCtld/DistConfig/Unsupported.html
[OsCtld::DistConfig]: https://ref.vpsadminos.org/osctld/OsCtld/DistConfig.html
[osctld/templates/]: https://github.com/vpsfreecz/vpsadminos/tree/master/osctld/templates
[OsCtld::Template]: https://ref.vpsadminos.org/osctld/OsCtld/Template.html
