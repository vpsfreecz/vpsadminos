require 'linux/netlink/route'
require 'linux/netlink/route/link_handler'

module OsCtld
  module Utils::Ip
    class LinkIdentityError < StandardError; end
    class LinkNotFound < LinkIdentityError; end

    # @return [OsCtl::Lib::SystemCommandResult]
    def ip(ip_v, args, **opts)
      cmd = ['ip']

      case ip_v
      when 4
        cmd << '-4'
      when 6
        cmd << '-6'
      when :all
        # nothing to do
      else
        raise "unknown IP version '#{ip_v}'"
      end

      cmd.concat(args.map(&:to_s))
      syscmd_argv(cmd, opts)
    end

    # @return [OsCtl::Lib::SystemCommandResult]
    def tc(args, **opts)
      cmd = ['tc'].concat(args.map(&:to_s))
      syscmd_argv(cmd, opts)
    end

    # Resolve a live link by name and require the expected kernel kind before
    # returning its positive ifindex.
    def link_ifindex_by_name(expected_name:, expected_kind:)
      unless expected_name.is_a?(String) && !expected_name.empty?
        raise ArgumentError, "invalid expected network interface name #{expected_name.inspect}"
      end
      unless expected_kind.is_a?(String) && !expected_kind.empty?
        raise ArgumentError, "invalid expected network interface kind #{expected_kind.inspect}"
      end

      Linux::Netlink::Route::Socket.open do |nl|
        begin
          link = nl.link[expected_name]
        rescue KeyError, Errno::ENODEV
          link = nil
        end

        unless link
          raise LinkNotFound,
                "network interface #{expected_name.inspect} " \
                "(kind #{expected_kind.inspect}) is absent"
        end

        unless link.index.is_a?(Integer) && link.index > 0 &&
               link.ifname == expected_name && link.kind == expected_kind
          raise LinkIdentityError,
                "network interface #{expected_name.inspect} " \
                "(kind #{expected_kind.inspect}) is now #{link.ifname.inspect} " \
                "(ifindex #{link.index.inspect}, kind #{link.kind.inspect})"
        end

        link.index
      end
    end

    # Delete a recorded link only while the live object at +ifindex+ still has
    # its expected name and kernel link kind. An index can be reused after the
    # original link disappears, so the index alone is not an identity proof.
    #
    # RTM_DELLINK ignores IFLA_IFNAME whenever ifi_index is positive. Delete by
    # the daemon-reserved name instead, so the kernel resolves that name and
    # removes the selected object under one RTNL critical section. This keeps a
    # link which reuses +ifindex+ between the lookup and deletion out of scope.
    def delete_link_by_ifindex(ifindex, expected_name:, expected_kind:)
      unless ifindex.is_a?(Integer) && ifindex > 0
        raise ArgumentError, "invalid network interface index #{ifindex.inspect}"
      end
      unless expected_name.is_a?(String) && !expected_name.empty?
        raise ArgumentError, "invalid expected network interface name #{expected_name.inspect}"
      end
      unless expected_kind.is_a?(String) && !expected_kind.empty?
        raise ArgumentError, "invalid expected network interface kind #{expected_kind.inspect}"
      end

      Linux::Netlink::Route::Socket.open do |nl|
        begin
          link = nl.link[ifindex]
        rescue KeyError, Errno::ENODEV
          link = nil
        end

        unless link
          raise LinkIdentityError,
                "recorded network interface #{expected_name.inspect} " \
                "(ifindex #{ifindex}, kind #{expected_kind.inspect}) is absent"
        end

        unless link.index == ifindex && link.ifname == expected_name && link.kind == expected_kind
          raise LinkIdentityError,
                "recorded network interface #{expected_name.inspect} " \
                "(ifindex #{ifindex}, kind #{expected_kind.inspect}) is now " \
                "#{link.ifname.inspect} (ifindex #{link.index}, kind #{link.kind.inspect})"
        end

        nl.cmd(
          Linux::RTM_DELLINK,
          Linux::Netlink::IFInfo.new(
            index: 0,
            ifname: expected_name
          )
        )
      end
    end
  end
end
