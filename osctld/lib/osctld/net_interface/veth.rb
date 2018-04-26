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
        @ips = Hash[ cfg['ip_addresses'].map do |v, ips|
          [v, ips.map { |ip| IPAddress.parse(ip) }]
        end]

      else
        @ips = {4 => [], 6 => []}
      end
    end

    def save
      super.merge(
        'ip_addresses' => Hash[@ips.map { |v, ips| [v, ips.map(&:to_string)] }],
      )
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

        unless File.exist?(hook_path(v))
          File.symlink(OsCtld::hook_src("veth-#{v}"), hook_path(v))
        end
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
      {
        name: name,
        index: index,
        hwaddr: hwaddr,
        hook_veth_up: hook_path('up'),
        hook_veth_down: hook_path('down'),
      }
    end

    def up(veth)
      @veth = veth

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
      @veth = nil

      Eventd.report(
        :ct_netif,
        action: :down,
        pool: ct.pool.name,
        id: ct.id,
        name: name,
      )
    end

    def ips(v)
      @ips[v].clone
    end

    # @param addr [IPAddress]
    def add_ip(addr)
      @ips[addr.ipv4? ? 4 : 6] << addr
    end

    # @param addr [IPAddress]
    def del_ip(addr)
      @ips[addr.ipv4? ? 4 : 6].delete_if { |v| v == addr }
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
  end
end
