require 'libosctl'
require 'osctld/net_interface/base'

module OsCtld
  class NetInterface::Veth < NetInterface::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::SwitchUser

    attr_reader :veth

    def create(opts)
      super

      @ips = {4 => [], 6 => []}
    end

    def load(cfg)
      super

      if cfg['ip_addresses']
        @ips = load_ip_list(cfg['ip_addresses']) do |ips|
          ips.map { |ip| IPAddress.parse(ip) }
        end

      else
        @ips = {4 => [], 6 => []}
      end
    end

    def save
      inclusively do
        super.merge(
          'ip_addresses' => save_ip_list(@ips) { |v| v.map(&:to_string) },
        )
      end
    end

    def setup
      # Setup links for veth up/down hooks in rundir
      #
      # Because a CT can have multiple veth interfaces and they can be of
      # different types, we need to create hooks for specific veth interfaces,
      # so that we can identify which veth was the hook called for. We simply
      # symlink the hook to rundir and the symlink's name identifies the veth.
      Dir.mkdir(veth_hook_dir, 0711) unless Dir.exist?(veth_hook_dir)

      %w(up down).each do |v|
        Dir.mkdir(mode_path(v), 0711) unless Dir.exist?(mode_path(v))

        symlink = hook_path(v)
        hook_src = OsCtld::hook_src("veth-#{v}")

        if File.symlink?(symlink)
          if File.readlink(symlink) == hook_src
            next
          else
            File.unlink(symlink)
          end
        end

        File.symlink(hook_src, symlink)
      end

      return if ct.current_state != :running
      @veth = fetch_veth_name
    end

    def rename(new_name)
      %w(up down).each do |v|
        begin
          File.unlink(hook_path(v, name))

        rescue Errno::ENOENT
          # pass
        end

        File.symlink(OsCtld::hook_src("veth-#{v}"), hook_path(v, new_name))
      end

      super
    end

    def render_opts
      inclusively do
        {
          name: name,
          index: index,
          hwaddr: hwaddr,
          hook_veth_up: hook_path('up'),
          hook_veth_down: hook_path('down'),
        }
      end
    end

    def up(veth)
      exclusively { @veth = veth }

      Eventd.report(
        :ct_netif,
        action: :up,
        pool: ct.pool.name,
        id: ct.id,
        name: name,
        veth: veth,
      )
    end

    def down(veth)
      exclusively { @veth = nil }

      Eventd.report(
        :ct_netif,
        action: :down,
        pool: ct.pool.name,
        id: ct.id,
        name: name,
      )
    end

    def active_ip_versions
      inclusively { [4, 6].delete_if { |v| @ips[v].empty? } }
    end

    def ips(v)
      inclusively { @ips[v].clone }
    end

    # @param addr [IPAddress]
    # @param prefix [Boolean] check also address prefix
    def has_ip?(addr, prefix: true)
      ip_v = addr.ipv4? ? 4 : 6

      exclusively do
        if prefix
          @ips[ip_v].include?(addr)
        else
          @ips[ip_v].detect { |v| v.to_s == addr.to_s } ? true : false
        end
      end
    end

    # @param addr [IPAddress]
    def add_ip(addr)
      exclusively { @ips[addr.ipv4? ? 4 : 6] << addr }
    end

    # @param addr [IPAddress]
    def del_ip(addr)
      exclusively { @ips[addr.ipv4? ? 4 : 6].delete_if { |v| v == addr } }
    end

    # @param ip_v [Integer, nil]
    def del_all_ips(ip_v = nil)
      exclusively do
        (ip_v ? [ip_v] : [4, 6]).each do |v|
          @ips[v].clone.each { |addr| del_ip(addr) }
        end
      end
    end

    protected
    def fetch_veth_name
      ret = ct_control(ct, :veth_name, {
        id: ct.id,
        index: index,
      })

      fail "Unable to get veth name: #{ret[:message]}" unless ret[:status]

      log(:info, ct, "Discovered name for veth ##{index}: #{ret[:output]}")
      ret[:output]
    end

    def veth_hook_dir
      File.join(ct.pool.hook_dir, 'veth')
    end

    def mode_path(mode)
      File.join(veth_hook_dir, mode)
    end

    def hook_path(mode, name = nil)
      File.join(mode_path(mode), "#{@ct.id}.#{name || self.name}")
    end

    # Take an internal representation of an IP list and return a version to
    # store in the config file.
    #
    # The internal representation is a hash, where keys are IP versions as
    # integer and the yielded value is either a list of addresses, i.e. an array
    # of string, or just one address (string). The caller decides how to encode
    # the value.
    #
    # The returned hash has IP versions in the hash encoded as strings, i.e.
    # `v4` or v6`. This is to allow storing the config in JSON, which does not
    # support integer object keys.
    #
    # @yieldparam value [String, Array<String>]
    # @return [Hash<String, String>, Hash<String, Array<String>>]
    def save_ip_list(ip_list)
      Hash[ip_list.map { |ip_v, value| ["v#{ip_v}", yield(value)] }]
    end

    # Take an IP list stored in a config file and return an internal
    # representation, see #{save_ip_list}.
    #
    # @yieldparam value [String, Array<String>]
    # @return [Hash<Integer, String>, Hash<Integer, Array<String>>]
    def load_ip_list(ip_list)
      Hash[ ip_list.map do |ip_v, value|
        # Load also integer keys for backward compatibility
        if [4, 6].include?(ip_v)
          [ip_v, yield(value)]

        elsif /^v(4|6)$/ =~ ip_v
          [$1.to_i, yield(value)]

        else
          fail "unsupported IP version '#{ip_v}': expected v4 or v6"
        end
      end]
    end
  end
end
