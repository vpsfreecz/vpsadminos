require 'json'
require 'libosctl'
require 'osctld/net_interface/base'

module OsCtld
  class NetInterface::Veth < NetInterface::Base
    SHAPER_QDISC_HANDLE = '50c7:'.freeze
    SHAPER_FILTER_PREF = 10
    SHAPER_FILTER_HANDLE = 1

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::Ip
    include Utils::SwitchUser

    attr_reader :veth, :runtime_health_error

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
      @ips = { 4 => [], 6 => [] }
    end

    def load(cfg)
      super

      @tx_queues = cfg.fetch('tx_queues', 1)
      @rx_queues = cfg.fetch('rx_queues', 1)

      @ips = if cfg['ip_addresses']
               load_ip_list(cfg['ip_addresses']) do |ips|
                 ips.map { |ip| IPAddress.parse(ip) }
               end

             else
               { 4 => [], 6 => [] }
             end
    end

    def save
      inclusively do
        super.merge(
          'tx_queues' => tx_queues,
          'rx_queues' => rx_queues,
          'ip_addresses' => save_ip_list(@ips) { |v| v.map(&:to_string) }
        )
      end
    end

    def set(opts)
      @tx_queues = opts[:tx_queues] if opts[:tx_queues]
      @rx_queues = opts[:rx_queues] if opts[:rx_queues]

      orig_max_rx = max_rx
      orig_max_tx = max_tx
      orig_enable = enable

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

      # rubocop:disable Style/GuardClause

      if opts.has_key?(:enable) && opts[:enable] != orig_enable
        if !opts[:enable] && orig_enable
          begin
            ip(:all, %W[link set #{veth} down])
          rescue SystemCommandFailed => e
            log(:warn, ct, "Unable to disable host veth #{veth}: #{e.message}")
          end
        elsif opts[:enable] && !orig_enable
          begin
            ip(:all, %W[link set #{veth} up])
          rescue SystemCommandFailed => e
            log(:warn, ct, "Unable to enable host veth #{veth}: #{e.message}")
          end
        end
      end

      # rubocop:enable Style/GuardClause
    end

    def setup
      # Setup links for veth up/down hooks in rundir
      #
      # Because a CT can have multiple veth interfaces and they can be of
      # different types, we need to create hooks for specific veth interfaces,
      # so that we can identify which veth was the hook called for. We simply
      # symlink the hook to rundir and the symlink's name identifies the veth.
      begin
        Dir.mkdir(veth_hook_dir, 0o711)
      rescue Errno::EEXIST
        # ignore
      end

      %w[up down].each do |v|
        begin
          Dir.mkdir(mode_path(v), 0o711)
        rescue Errno::EEXIST
          # ignore
        end

        symlink = hook_path(v)
        hook_src = OsCtld.hook_src("veth-#{v}")

        if File.symlink?(symlink)
          next if File.readlink(symlink) == hook_src

          File.unlink(symlink)

        end

        File.symlink(hook_src, symlink)
      end

      observe_runtime
    end

    def observe_runtime
      return unless %i[running frozen].include?(ct.fresh_runtime_state)

      @veth = fetch_veth_name
      if host_link_exists?(@veth)
        @runtime_health_error = nil
        return
      end

      @runtime_health_error = "host veth #{@veth.inspect} does not exist"
      log(:warn, ct, @runtime_health_error)
      @veth = nil
    end

    # Reapply host-side state which can be lost independently of the
    # container. A missing enabled veth is not repairable in place because the
    # peer exists in the container network namespace; callers must perform a
    # controlled generation restart.
    def reconcile_runtime(legacy_runtime: false)
      unless veth
        return {
          status: enable ? 'missing' : 'disabled_missing',
          interface: name,
          error: runtime_health_error || 'host veth is unavailable'
        }
      end

      ip(:all, %W[link set #{veth} #{enable ? 'up' : 'down'}])
      reconcile_runtime_shaper_rx(legacy_runtime:)
      reconcile_runtime_shaper_tx(legacy_runtime:)
      { status: 'healthy', interface: name, veth: }
    rescue StandardError => e
      {
        status: 'error',
        interface: name,
        veth:,
        error: "#{e.class}: #{e.message}"
      }
    end

    def rename(new_name)
      %w[up down].each do |v|
        begin
          File.unlink(hook_path(v, name))
        rescue Errno::ENOENT
          # pass
        end

        File.symlink(OsCtld.hook_src("veth-#{v}"), hook_path(v, new_name))
      end

      super
    end

    def render_opts(run_conf: nil)
      inclusively do
        {
          name:,
          index:,
          hwaddr:,
          tx_queues:,
          rx_queues:,
          hook_veth_up: hook_path('up', run_conf:),
          hook_veth_down: hook_path('down', run_conf:)
        }
      end
    end

    def prepare_run_hooks(run_conf)
      %w[up down].each do |mode|
        path = hook_path(mode, run_conf:)
        source = OsCtld.hook_src("veth-#{mode}")

        next if File.symlink?(path) && File.readlink(path) == source

        File.unlink(path) if File.symlink?(path)
        File.symlink(source, path)
      end
    end

    def run_hook_paths(run_conf)
      %w[up down].map { |mode| hook_path(mode, run_conf:) }
    end

    def remove_run_hooks(run_conf)
      run_hook_paths(run_conf).each do |path|
        File.unlink(path)
      rescue Errno::ENOENT
        nil
      end
    end

    def up(veth)
      exclusively { @veth = veth }

      ip(:all, %W[link set #{veth} down]) unless enable

      set_shaper_rx if max_rx > 0
      set_shaper_tx if max_tx > 0

      Eventd.report(
        :ct_netif,
        action: :up,
        pool: ct.pool.name,
        id: ct.id,
        name:,
        veth:,
        enable:
      )
    end

    def down(host_veth = nil)
      veth_name = host_veth || veth
      return unless veth_name

      ifb_name = "ifb#{veth_name}"

      exclusively { @veth = nil if host_veth.nil? || @veth == host_veth }

      # lxc-user-nic does not support deletion of veth interfaces, delete it ourselves
      log(:info, ct, "Removing host veth #{veth_name}")

      begin
        ip(:all, %W[link del #{veth_name}])
      rescue SystemCommandFailed => e
        log(:warn, ct, "Unable to delete host veth #{veth_name}: #{e.message}")
      end

      if max_tx > 0
        begin
          ip(:all, %W[link del #{ifb_name}])
        rescue SystemCommandFailed => e
          log(:warn, ct, "Unable to delete ifb host veth #{ifb_name}: #{e.message}")
        end
      end

      Eventd.report(
        :ct_netif,
        action: :down,
        pool: ct.pool.name,
        id: ct.id,
        name:
      )
    end

    def is_created?
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
      ret = super
      ret.instance_variable_set('@veth', nil)
      ret.instance_variable_set('@ips', @ips.transform_values(&:dup))
      ret
    end

    protected

    def fetch_veth_name
      v = ContainerControl::Commands::VethName.run!(ct, index)
      log(:info, ct, "Discovered name for veth ##{index}: #{v}")
      v
    end

    def host_link_exists?(name)
      name && File.exist?(File.join('/sys/class/net', name))
    end

    def ifb_veth
      "ifb#{veth}"
    end

    def reconcile_runtime_shaper_rx(legacy_runtime: false)
      root_qdisc = runtime_qdiscs(veth).detect do |qdisc|
        qdisc['root']
      end

      if max_rx > 0
        if root_qdisc.nil? \
            || kernel_default_qdisc?(root_qdisc) \
            || (legacy_runtime && legacy_cake_matches?(root_qdisc, max_rx))
          replace_cake(veth, max_rx)
        elsif osctld_cake?(root_qdisc)
          replace_cake(veth, max_rx) unless cake_matches?(root_qdisc, max_rx)
        else
          raise 'unowned receive qdisc conflicts with configured shaping'
        end
      elsif osctld_cake?(root_qdisc)
        tc(%W[qdisc delete root dev #{veth}], valid_rcs: [2])
      end
    end

    def reconcile_runtime_shaper_tx(legacy_runtime: false)
      qdiscs = runtime_qdiscs(veth)
      filters = runtime_filters(veth)
      ifb_exists = Dir.exist?("/sys/devices/virtual/net/#{ifb_veth}")
      ifb_qdiscs = ifb_exists ? runtime_qdiscs(ifb_veth) : []
      owned_filters = filters.select { |filter| osctld_tx_filter?(filter) }
      legacy_filters = if legacy_runtime && max_tx > 0
                         filters.select do |filter|
                           !osctld_tx_filter?(filter) \
                             && legacy_tx_filter?(filter, qdiscs, ifb_qdiscs)
                         end
                       else
                         []
                       end
      foreign_filters = filters - owned_filters - legacy_filters

      if max_tx > 0
        ifb_root = ifb_qdiscs.detect { |qdisc| qdisc['root'] }
        legacy_ifb_owned = legacy_runtime \
          && (legacy_filters.one? || owned_filters.any?) \
          && legacy_cake_matches?(ifb_root, max_tx, besteffort: true)
        if ifb_root \
            && !osctld_cake?(ifb_root) \
            && !legacy_ifb_owned
          raise 'unowned transmit qdisc conflicts with configured shaping'
        end
        if legacy_filters.length > 1
          raise 'multiple legacy transmit filters have ambiguous ownership'
        end
        if legacy_filters.any? && owned_filters.any?
          raise 'owned and legacy transmit filters coexist'
        end

        conflicting = foreign_filters.any? do |filter|
          tx_filter_action_matches?(filter)
        end
        if conflicting
          raise 'unowned transmit filter conflicts with configured shaping'
        end
      end

      if max_tx > 0
        unless ifb_exists
          ip(:all, %W[link add name #{ifb_veth} type ifb])
        end
        unless qdiscs.any? { |qdisc| qdisc['kind'] == 'ingress' }
          tc(%W[qdisc add dev #{veth} handle ffff: ingress])
        end
        ifb_cake = ifb_qdiscs.detect { |qdisc| qdisc['root'] }
        unless cake_matches?(ifb_cake, max_tx, besteffort: true)
          replace_cake(ifb_veth, max_tx, besteffort: true)
        end
        ip(:all, %W[link set #{ifb_veth} up])
        desired_filter = owned_filters.detect do |filter|
          tx_filter_matches?(filter)
        end
        if desired_filter
          owned_filters.reject { |filter| filter.equal?(desired_filter) }
                       .each { |filter| delete_runtime_tx_filter(filter) }
        else
          # Deleting old entries has to happen before replace because all
          # osctld-owned filters deliberately share the reserved identity.
          owned_filters.each { |filter| delete_runtime_tx_filter(filter) }
        end
        legacy_filters.each { |filter| delete_runtime_tx_filter(filter) }
        unless desired_filter
          replace_runtime_tx_filter
        end
        return
      end

      owned_filters.each { |filter| delete_runtime_tx_filter(filter) }
      owned_ifb = ifb_qdiscs.any? { |qdisc| osctld_cake?(qdisc) }
      ownership_evidence = owned_filters.any? || owned_ifb
      if ownership_evidence \
          && foreign_filters.empty? \
          && qdiscs.any? { |qdisc| qdisc['kind'] == 'ingress' }
        tc(
          %W[qdisc delete dev #{veth} handle ffff: ingress],
          valid_rcs: [2]
        )
      end
      return unless ownership_evidence && foreign_filters.empty?
      return unless ifb_exists

      ip(:all, %W[link del #{ifb_veth}], valid_rcs: [1])
    end

    def runtime_qdiscs(device)
      JSON.parse(tc(%W[-json qdisc show dev #{device}]).output)
    end

    def runtime_filters(device)
      JSON.parse(
        tc(%W[-json filter show dev #{device} parent ffff:]).output
      )
    end

    def osctld_tx_filter?(filter)
      filter['kind'] == 'matchall' \
        && filter['pref'].to_i == SHAPER_FILTER_PREF \
        && filter.dig('options', 'handle').to_i == SHAPER_FILTER_HANDLE
    end

    def tx_filter_matches?(filter)
      osctld_tx_filter?(filter) \
        && filter['protocol'].to_s == 'all' \
        && tx_filter_action_matches?(filter)
    end

    def tx_filter_action_matches?(filter)
      actions = filter.dig('options', 'actions') || []
      actions.length == 1 \
        && actions.first['kind'] == 'mirred' \
        && actions.first['mirred_action'] == 'redirect' \
        && actions.first['direction'] == 'egress' \
        && actions.first['to_dev'] == ifb_veth
    end

    def legacy_tx_filter?(filter, veth_qdiscs, ifb_qdiscs)
      return false unless filter['kind'] == 'matchall'
      return false unless tx_filter_action_matches?(filter)
      return false unless veth_qdiscs.any? { |qdisc| qdisc['kind'] == 'ingress' }

      ifb_qdiscs.any? { |qdisc| legacy_cake?(qdisc) }
    end

    def osctld_cake?(qdisc)
      qdisc && qdisc['handle'] == SHAPER_QDISC_HANDLE
    end

    def kernel_default_qdisc?(qdisc)
      qdisc && qdisc['kind'] == 'noqueue' && qdisc['root'] \
        && qdisc['handle'] == '0:'
    end

    def legacy_cake?(qdisc)
      qdisc && qdisc['kind'] == 'cake' && qdisc['root'] \
        && !osctld_cake?(qdisc)
    end

    def legacy_cake_matches?(qdisc, bandwidth, besteffort: false)
      return false unless legacy_cake?(qdisc)

      cake_options_match?(qdisc, bandwidth, besteffort:)
    end

    def cake_matches?(qdisc, bandwidth, besteffort: false)
      return false unless qdisc && qdisc['kind'] == 'cake' && qdisc['root']
      return false unless osctld_cake?(qdisc)

      cake_options_match?(qdisc, bandwidth, besteffort:)
    end

    def cake_options_match?(qdisc, bandwidth, besteffort: false)
      expected_bandwidth = (bandwidth + 7) / 8
      return false unless qdisc.dig('options', 'bandwidth').to_i == expected_bandwidth
      return true unless besteffort

      qdisc.dig('options', 'diffserv') == 'besteffort'
    end

    def replace_cake(device, bandwidth, besteffort: false)
      args = %W[
        qdisc replace dev #{device} root handle #{SHAPER_QDISC_HANDLE}
        cake bandwidth #{bandwidth}bit
      ]
      args << 'besteffort' if besteffort
      tc(args)
    end

    def replace_runtime_tx_filter
      tc(
        %W[
          filter replace dev #{veth} parent ffff: protocol all
          pref #{SHAPER_FILTER_PREF} handle #{SHAPER_FILTER_HANDLE} matchall
          action mirred egress redirect dev #{ifb_veth}
        ]
      )
    end

    def delete_runtime_tx_filter(filter)
      args = %W[filter delete dev #{veth} parent ffff:]
      args.push('protocol', filter['protocol'].to_s) if filter['protocol']
      args.push('pref', filter.fetch('pref').to_s)
      handle = filter.dig('options', 'handle')
      args.push('handle', handle.to_s, filter.fetch('kind')) if handle
      tc(args, valid_rcs: [2])
    end

    def set_shaper_rx
      reconcile_runtime_shaper_rx
    end

    def unset_shaper_rx
      reconcile_runtime_shaper_rx
    end

    def set_shaper_tx
      reconcile_runtime_shaper_tx
    end

    def unset_shaper_tx
      reconcile_runtime_shaper_tx
    end

    def veth_hook_dir
      File.join(ct.pool.hook_dir, 'veth')
    end

    def mode_path(mode)
      File.join(veth_hook_dir, mode)
    end

    def hook_path(mode, name = nil, run_conf: nil)
      suffix = run_conf ? ".#{run_conf.run_id.key}" : ''
      File.join(mode_path(mode), "#{@ct.id}.#{name || self.name}#{suffix}")
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
      ip_list.to_h { |ip_v, value| ["v#{ip_v}", yield(value)] }
    end

    # Take an IP list stored in a config file and return an internal
    # representation, see #{save_ip_list}.
    #
    # @yieldparam value [String, Array<String>]
    # @return [Hash<Integer, String>, Hash<Integer, Array<String>>]
    def load_ip_list(ip_list)
      ip_list.to_h do |ip_v, value|
        # Load also integer keys for backward compatibility
        if [4, 6].include?(ip_v)
          [ip_v, yield(value)]

        elsif /^v(4|6)$/ =~ ip_v
          [::Regexp.last_match(1).to_i, yield(value)]

        else
          raise "unsupported IP version '#{ip_v}': expected v4 or v6"
        end
      end
    end
  end
end
