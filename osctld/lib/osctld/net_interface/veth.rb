require 'libosctl'
require 'osctld/net_interface/base'

module OsCtld
  class NetInterface::Veth < NetInterface::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::Ip
    include Utils::SwitchUser

    attr_reader :veth

    # Number of transmit queues
    # @return [Integer]
    attr_reader :tx_queues

    # Number of receive queues
    # @return [Integer]
    attr_reader :rx_queues

    def create(opts)
      super

      @tx_queues = opts.fetch(:tx_queues, 1)
      @rx_queues = opts.fetch(:rx_queues, 1)
      @ips = {4 => [], 6 => []}
    end

    def load(cfg)
      super

      @tx_queues = cfg.fetch('tx_queues', 1)
      @rx_queues = cfg.fetch('rx_queues', 1)

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
          'tx_queues' => tx_queues,
          'rx_queues' => rx_queues,
          'ip_addresses' => save_ip_list(@ips) { |v| v.map(&:to_string) },
        )
      end
    end

    def set(opts)
      @tx_queues = opts[:tx_queues] if opts[:tx_queues]
      @rx_queues = opts[:rx_queues] if opts[:rx_queues]

      orig_max_rx = max_rx
      orig_max_tx = max_tx

      # max_tx/rx is assigned by the parent
      super

      return if veth.nil?

      if opts[:max_rx] && opts[:max_rx] != orig_max_rx
        if max_rx > 0
          set_shaper_rx
        else
          unset_shaper_rx
        end
      end

      if opts[:max_tx] && opts[:max_tx] != orig_max_tx
        if max_tx > 0
          set_shaper_tx
        else
          unset_shaper_tx
        end
      end
    end

    def setup
      # Setup links for veth up/down hooks in rundir
      #
      # Because a CT can have multiple veth interfaces and they can be of
      # different types, we need to create hooks for specific veth interfaces,
      # so that we can identify which veth was the hook called for. We simply
      # symlink the hook to rundir and the symlink's name identifies the veth.
      begin
        Dir.mkdir(veth_hook_dir, 0711)
      rescue Errno::EEXIST
      end

      %w(up down).each do |v|
        begin
          Dir.mkdir(mode_path(v), 0711)
        rescue Errno::EEXIST
        end

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

      return if ct.fresh_state != :running
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
          tx_queues: tx_queues,
          rx_queues: rx_queues,
          hook_veth_up: hook_path('up'),
          hook_veth_down: hook_path('down'),
        }
      end
    end

    def up(veth)
      exclusively { @veth = veth }

      set_shaper_rx if max_rx > 0
      set_shaper_tx if max_tx > 0

      Eventd.report(
        :ct_netif,
        action: :up,
        pool: ct.pool.name,
        id: ct.id,
        name: name,
        veth: veth,
      )
    end

    def down(host_veth = nil)
      veth_name = host_veth || veth
      ifb_name = ifb_veth

      exclusively { @veth = nil }

      # TODO: Removing the veth should be done with LXC, but it doesn't work on
      # os/osctl
      log(:info, ct, "Removing host veth #{veth_name}")

      begin
        ip(:all, %W(link del #{veth_name}))
      rescue SystemCommandFailed => e
        log(:warn, ct, "Unable to delete host veth #{veth_name}: #{e.message}")
      end

      if max_tx > 0
        begin
          ip(:all, %W(link del #{ifb_name}))
        rescue SystemCommandFailed => e
          log(:warn, ct, "Unable to delete ifb host veth #{ifb_name}: #{e.message}")
        end
      end

      Eventd.report(
        :ct_netif,
        action: :down,
        pool: ct.pool.name,
        id: ct.id,
        name: name,
      )
    end

    def is_up?
      inclusively { !veth.nil? }
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

    def dup(new_ct)
      ret = super(new_ct)
      ret.instance_variable_set('@veth', nil)
      ret
    end

    protected
    def fetch_veth_name
      v = ContainerControl::Commands::VethName.run!(ct, index)
      log(:info, ct, "Discovered name for veth ##{index}: #{v}")
      v
    end

    def ifb_veth
      "ifb#{veth}"
    end

    def set_shaper_rx
      tc(%W(qdisc delete root dev #{veth}), valid_rcs: [2])
      tc(%W(qdisc add root dev #{veth} cake bandwidth #{max_rx}bit))
    end

    def unset_shaper_rx
      tc(%W(qdisc delete root dev #{veth}), valid_rcs: [2])
    end

    def set_shaper_tx
      ifb_exists = Dir.exist?("/sys/devices/virtual/net/#{ifb_veth}")

      unless ifb_exists
        ip(:all, %W(link add name #{ifb_veth} type ifb))
        tc(%W(qdisc del dev #{veth} ingress), valid_rcs: [2])
        tc(%W(qdisc add dev #{veth} handle ffff: ingress))
      end

      tc(%W(qdisc del dev #{ifb_veth} root), valid_rcs: [2])
      tc(%W(qdisc add dev #{ifb_veth} root cake bandwidth #{max_tx}bit besteffort))

      unless ifb_exists
        ip(:all, %W(link set #{ifb_veth} up))
        tc(%W(filter add dev #{veth} parent ffff: matchall action mirred egress redirect dev #{ifb_veth}))
      end
    end

    def unset_shaper_tx
      tc(%W(filter delete dev #{veth} parent ffff:))
      tc(%W(qdisc delete dev #{veth} handle ffff: ingress))
      ip(:all, %W(link del #{ifb_veth}))
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
