require 'ipaddress'

module OsCtld
  class NetInterface::Routed < NetInterface::Base
    type :routed
    VETH_HOOKDIR = File.join(OsCtld::RunState::HOOKDIR, 'veth')

    include Utils::Log
    include Utils::System
    include Utils::Ip
    include Utils::SwitchUser

    attr_reader :via, :veth

    # @param opts [Hash]
    # @option opts [String] name
    # @option opts [String] via
    def create(opts)
      super
      @via = Hash[ opts[:via].map do |k, v|
        [k, Routing::Via.for(IPAddress.parse(v))]
      end]
      @ips = {4 => [], 6 => []}
    end

    def load(cfg)
      super

      @via = Hash[ (cfg['via'] || {}).map do |k, v|
        [k, Routing::Via.for(IPAddress.parse(v))]
      end]

      if cfg['ip_addresses']
        @ips = Hash[ cfg['ip_addresses'].map do |v, ips|
          [v, ips.map { |ip| IPAddress.parse(ip) }]
        end]

      else
        @ips = {4 => [], 6 => []}
      end
    end

    def save
      ret = super
      ret.update({
        'via' => Hash[@via.map { |k,v| [k, v.net_addr.to_string] }],
        'ip_addresses' => Hash[@ips.map { |v, ips| [v, ips.map(&:to_string)] }],
      })
      ret
    end

    def setup
      @host_setup = {}

      # Setup links for veth up/down hooks in rundir
      #
      # Because a CT can have multiple veth interfaces and they can be of
      # different types, we need to create hooks for specific veth interfaces,
      # so that we can identify which veth was the hook called for. We simply
      # symlink the hook to rundir and the symlink's name identifies the veth.
      Dir.mkdir(VETH_HOOKDIR) unless Dir.exist?(VETH_HOOKDIR)
      %w(up down).each do |v|
        Dir.mkdir(mode_path(v)) unless Dir.exist?(mode_path(v))

        unless File.exist?(hook_path(v))
          File.symlink(OsCtld::hook_src("veth-#{v}"), hook_path(v))
        end
      end

      # Setup routing
      return if ct.current_state != :running
      @veth = fetch_veth_name

      iplist = ip(:all, [:addr, :show, :dev, veth], valid_rcs: [1])

      if iplist[:exitstatus] == 1
        log(
          :info,
          "CT #{ct.id}",
          "veth '#{veth}' of container '#{ct.id}' no longer exists, "+
          "ignoring"
        )
        @veth = nil
        return
      end

      [4, 6].each do |ip_v|
        net = via[ip_v]
        next unless net

        inet = ip_v == 4 ? 'inet' : 'inet6'

        if /#{inet} #{Regexp.escape(net.host_ip.to_string)}/ =~ iplist[:output]
          log(
            :info,
            "CT #{ct.id}",
            "Discovered IPv#{ip_v} configuration for routed veth #{name}"
          )

          @host_setup[ip_v] = true
        end
      end
    end

    def render_opts
      {
        name: name,
        index: index,
        hook_veth_up: hook_path('up'),
        hook_veth_down: hook_path('down'),
      }
    end

    def up(veth)
      @veth = veth

      [4, 6].each do |v|
        next if @ips[v].empty?

        setup_routing(v) unless @host_setup[v]

        @ips[v].each do |addr|
          ip(v, [
            :route, :add,
            addr.to_string, :via, via[v].ct_ip.to_s, :dev, veth
          ])
        end
      end
    end

    def down(veth)
      @veth = nil
      @host_setup = {}
    end

    def ips(v)
      @ips[v].clone
    end

    def can_add_ip?(addr)
      !@via[addr.ipv4? ? 4 : 6].nil?
    end

    def active_ip_versions
      [4, 6].delete_if { |v| @via[v].nil? }
    end

    def add_ip(addr)
      v = addr.ipv4? ? 4 : 6
      @ips[v] << addr

      ct.inclusively do
        next if ct.state != :running

        setup_routing(v) unless @host_setup[v]

        # Add host route
        ip(v, [
          :route, :add,
          addr.to_string, :via, via[v].ct_ip.to_s, :dev, veth
        ])

        # Add IP within the CT
        ct_syscmd(
          ct,
          "ip -#{v} addr add #{addr.to_string} dev #{name}",
          valid_rcs: [2]
        )
      end
    end

    def del_ip(addr)
      v = addr.ipv4? ? 4 : 6
      @ips[v].delete_if { |v| v == addr }

      ct.inclusively do
        next if ct.state != :running

        # Remove host route
        ip(v, [
          :route, :del,
          addr.to_string, :via, via[v].ct_ip.to_s, :dev, veth
        ])

        # Remove IP from within the CT
        ct_syscmd(
          ct,
          "ip -#{v} addr del #{addr.to_string} dev #{name}",
          valid_rcs: [2]
        )
      end
    end

    protected
    def setup_routing(v)
      unless veth
        fail "Unable to setup routing for IPv#{v}: name of the veth "+
             "interface is not known"
      end

      ip(v, [:addr, :add, via[v].host_ip.to_string, :dev, veth])
      @host_setup[v] = true
    end

    def fetch_veth_name
      ret = ct_control(ct.user, :veth_name, {
        id: ct.id,
        index: index,
      })

      fail "Unable to get veth name: #{ret[:message]}" unless ret[:status]

      log(:info, "CT #{ct.id}", "Discovered name for veth ##{index}: #{ret[:output]}")
      ret[:output]
    end

    def mode_path(mode)
      File.join(VETH_HOOKDIR, mode)
    end

    def hook_path(mode)
      File.join(mode_path(mode), "#{@ct.id}.#{@index}")
    end
  end
end
