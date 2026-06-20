require 'libosctl'
require 'osctld/net_interface/base'

module OsCtld
  class NetInterface::Veth < NetInterface::Base
    class InvalidHostLink < NetInterface::HostLinkClaimError; end

    HOST_BOOT_ID_PATH = '/proc/sys/kernel/random/boot_id'.freeze
    HOST_BOOT_ID_PATTERN = /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::Ip
    include Utils::SwitchUser

    attr_reader :veth, :veth_ifindex, :ifb_ifindex

    # Number of transmit queues
    # @return [Integer]
    attr_reader :tx_queues

    # Number of receive queues
    # @return [Integer]
    attr_reader :rx_queues

    def self.current_host_boot_id
      boot_id = File.read(HOST_BOOT_ID_PATH).strip

      unless HOST_BOOT_ID_PATTERN.match?(boot_id)
        raise InvalidHostLink, "invalid current host boot ID #{boot_id.inspect}"
      end

      boot_id
    end

    def create(opts)
      super

      @tx_queues = opts.fetch(:tx_queues, 1)
      @rx_queues = opts.fetch(:rx_queues, 1)
      @veth = nil
      @veth_ifindex = nil
      @ifb_ifindex = nil
      @host_link_boot_id = nil
      @host_link_tainted = false
      @setup_state_changed = false
      @ips = { 4 => [], 6 => [] }
    end

    def load(cfg)
      super

      @tx_queues = cfg.fetch('tx_queues', 1)
      @rx_queues = cfg.fetch('rx_queues', 1)
      @setup_state_changed = false
      load_host_link(cfg['host_link'])

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
        data = super.merge(
          'tx_queues' => tx_queues,
          'rx_queues' => rx_queues,
          'ip_addresses' => save_ip_list(@ips) { |v| v.map(&:to_string) }
        )

        if @veth
          data['host_link'] = {
            'name' => @veth,
            'ifindex' => @veth_ifindex,
            'ifb_ifindex' => @ifb_ifindex,
            'boot_id' => @host_link_boot_id,
            'tainted' => @host_link_tainted
          }
        end

        data
      end
    end

    def set(opts)
      host_mutation_started = false

      NetInterface.sync_host_link_registry do
        orig_max_rx = max_rx
        orig_max_tx = max_tx
        orig_enable = enable
        host_change =
          (opts.has_key?(:max_rx) && opts[:max_rx] != orig_max_rx) ||
          (opts.has_key?(:max_tx) && opts[:max_tx] != orig_max_tx) ||
          (opts.has_key?(:enable) && opts[:enable] != orig_enable)

        if veth && host_change
          veth_name, veth_ifindex, = validate_down_callback
          if host_link_tainted?
            raise InvalidHostLink,
                  "host veth #{veth_name.inspect} is cleanup-tainted; " \
                  'complete recorded link deletion before changing host networking'
          end

          validate_live_host_link!(
            veth_name,
            veth_ifindex,
            expected_kind: 'veth'
          )
        end

        @tx_queues = opts[:tx_queues] if opts[:tx_queues]
        @rx_queues = opts[:rx_queues] if opts[:rx_queues]

        # max_tx/rx is assigned by the parent
        super

        return if veth.nil?

        host_mutation_started = host_change

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
      end
    rescue StandardError
      taint_host_link! if host_mutation_started
      raise
    end

    def setup(discover_host_links: true)
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

      # Imported/replaced config cannot cause legacy name discovery. It may
      # carry an identity only when Container overlaid the daemon's current
      # internal record before this manager was loaded.
      return unless discover_host_links

      NetInterface.sync_host_link_registry do
        # A persisted identity is the only safe authority after restart. Never
        # replace it through name discovery, even when the recorded link is now
        # absent or its index has been reused; down/recovery revalidates the
        # complete name/index/kind tuple on one netlink socket.
        return if inclusively { !@veth.nil? }
        return if ct.fresh_state != :running

        veth_name = fetch_veth_name
        veth_ifindex = host_veth_ifindex!(veth_name, expected_kind: 'veth')
        ifb_name = "ifb#{veth_name}"
        ifb_ifindex = if max_tx > 0
                        host_veth_ifindex(ifb_name, expected_kind: 'ifb')
                      end
        validate_unshared_host_link!(
          veth_name,
          veth_ifindex,
          ifb_ifindex,
          ifb_name: ifb_ifindex && ifb_name
        )
        exclusively do
          @veth = veth_name
          @veth_ifindex = veth_ifindex
          @ifb_ifindex = ifb_ifindex
          @host_link_boot_id = self.class.current_host_boot_id
          @host_link_tainted = false
          @setup_state_changed = true
        end
      end
    end

    def rename(new_name)
      NetInterface.sync_host_link_registry do
        if inclusively { !@veth.nil? }
          raise InvalidHostLink,
                "network interface #{name.inspect} still owns a host link; " \
                'complete lifecycle cleanup before renaming it'
        end

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
    end

    def render_opts
      inclusively do
        {
          name:,
          index:,
          hwaddr:,
          tx_queues:,
          rx_queues:,
          hook_veth_up: hook_path('up'),
          hook_veth_down: hook_path('down')
        }
      end
    end

    def up(veth)
      NetInterface.sync_host_link_registry do
        veth_name, ifindex = validate_up_callback(veth)

        exclusively do
          if @veth && (@veth != veth_name || @veth_ifindex != ifindex)
            raise InvalidHostLink,
                  "host veth identity changed from #{@veth}(#{@veth_ifindex}) " \
                  "to #{veth_name}(#{ifindex})"
          end

          @veth = veth_name
          @veth_ifindex = ifindex
          @host_link_boot_id = self.class.current_host_boot_id
          @host_link_tainted = false
        end
        persist_host_link_state

        ip(:all, %W[link set #{veth_name} down]) unless enable

        set_shaper_rx if max_rx > 0
        set_shaper_tx if max_tx > 0

        Eventd.report(
          :ct_netif,
          action: :up,
          pool: ct.pool.name,
          id: ct.id,
          name:,
          veth: veth_name,
          enable:
        )

        veth_name
      rescue StandardError
        taint_host_link!
        raise
      end
    end

    def down(host_veth = nil)
      NetInterface.sync_host_link_registry do
        veth_name, expected_ifindex, expected_ifb_ifindex =
          validate_down_callback(host_veth)
        return unless veth_name

        # lxc-user-nic does not support deletion of veth interfaces, delete it ourselves
        log(:info, ct, "Removing host veth #{veth_name} (ifindex #{expected_ifindex})")

        if expected_ifb_ifindex
          delete_recorded_host_link!(
            expected_ifb_ifindex,
            "ifb#{veth_name}",
            'ifb'
          )
          exclusively { @ifb_ifindex = nil }
          persist_host_link_state
        end

        delete_recorded_host_link!(expected_ifindex, veth_name, 'veth')

        exclusively do
          @veth = nil
          @veth_ifindex = nil
          @ifb_ifindex = nil
          @host_link_boot_id = nil
          @host_link_tainted = false
        end
        persist_host_link_state

        Eventd.report(
          :ct_netif,
          action: :down,
          pool: ct.pool.name,
          id: ct.id,
          name:
        )

        veth_name
      rescue StandardError
        taint_host_link!
        raise
      end
    end

    # Validate an LXC veth-up callback without changing interface state.
    # @return [Array(String, Integer)] host link name and ifindex
    def validate_up_callback(host_veth)
      NetInterface.sync_host_link_registry do
        veth_name = validate_kernel_ifname(host_veth)
        ifindex = host_veth_ifindex!(veth_name, expected_kind: 'veth')

        inclusively do
          if @host_link_tainted
            raise InvalidHostLink,
                  "host veth #{@veth.inspect} is cleanup-tainted; " \
                  'complete recorded link deletion before accepting another up callback'
          end

          if @veth && (@veth != veth_name || @veth_ifindex != ifindex)
            raise InvalidHostLink,
                  "host veth identity changed from #{@veth}(#{@veth_ifindex}) " \
                  "to #{veth_name}(#{ifindex})"
          end
        end

        validate_unshared_host_link!(
          veth_name,
          ifindex,
          nil,
          ifb_name: max_tx > 0 ? "ifb#{veth_name}" : nil
        )

        [veth_name, ifindex]
      end
    end

    # Validate an LXC veth-down callback against the identity recorded at up.
    # @return [Array(String, Integer, Integer), nil]
    def validate_down_callback(host_veth = nil)
      NetInterface.sync_host_link_registry do
        veth_name, expected_ifindex, expected_ifb_ifindex = host_link_identity
        return unless veth_name

        if host_veth
          callback_name = validate_kernel_ifname(host_veth)
          if callback_name != veth_name
            raise InvalidHostLink,
                  "host veth #{callback_name.inspect} does not match #{veth_name.inspect}"
          end
        end

        unless expected_ifindex.is_a?(Integer) && expected_ifindex > 0
          raise InvalidHostLink,
                "host veth #{veth_name.inspect} has no valid recorded ifindex"
        end

        if expected_ifb_ifindex && (
          !expected_ifb_ifindex.is_a?(Integer) || expected_ifb_ifindex <= 0
        )
          raise InvalidHostLink,
                "host veth #{veth_name.inspect} has invalid recorded IFB ifindex " \
                "#{expected_ifb_ifindex.inspect}"
        end
        if expected_ifb_ifindex == expected_ifindex
          raise InvalidHostLink,
                "host veth #{veth_name.inspect} reuses ifindex #{expected_ifindex} for its IFB"
        end

        validate_unshared_host_link!(
          veth_name,
          expected_ifindex,
          expected_ifb_ifindex,
          ifb_name: expected_ifb_ifindex && "ifb#{veth_name}"
        )

        [veth_name, expected_ifindex, expected_ifb_ifindex]
      end
    end

    # Return the host-side identities recorded when the links were created.
    # @return [Array(String, Integer, Integer)] veth name/index and IFB index
    def host_link_identity
      inclusively { [@veth, @veth_ifindex, @ifb_ifindex] }
    end

    def host_link_tainted?
      inclusively { @host_link_tainted }
    end

    # True when startup discovered or changed host-link state which was not in
    # the loaded config. Container persists it after installing the manager and
    # releasing its config-load lock.
    def setup_state_changed?
      inclusively { @setup_state_changed }
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
      ret.instance_variable_set('@veth_ifindex', nil)
      ret.instance_variable_set('@ifb_ifindex', nil)
      ret.instance_variable_set('@host_link_boot_id', nil)
      ret.instance_variable_set('@host_link_tainted', false)
      ret.instance_variable_set('@setup_state_changed', false)
      ret.instance_variable_set('@ips', @ips.transform_values(&:dup))
      ret
    end

    protected

    def fetch_veth_name
      v = ContainerControl::Commands::VethName.run!(ct, index)
      validate_kernel_ifname(v)
      log(:info, ct, "Discovered name for veth ##{index}: #{v}")
      v
    end

    def ifb_veth
      "ifb#{veth}"
    end

    def host_veth_ifindex(veth_name, expected_kind:)
      link_ifindex_by_name(
        expected_name: veth_name,
        expected_kind:
      )
    rescue Utils::Ip::LinkNotFound
      nil
    rescue Utils::Ip::LinkIdentityError => e
      raise InvalidHostLink, e.message
    end

    def host_veth_ifindex!(veth_name, expected_kind:)
      host_veth_ifindex(veth_name, expected_kind:) || raise(
        InvalidHostLink,
        "network interface #{veth_name.inspect} " \
        "(kind #{expected_kind.inspect}) is absent"
      )
    end

    def validate_kernel_ifname(name)
      value = String(name)

      if value.empty? || value.bytesize > 15 || %w[. ..].include?(value) \
         || value.match?(%r{[\x00-\x20/:]})
        raise InvalidHostLink, "invalid network interface name #{value.inspect}"
      end

      value
    end

    def set_shaper_rx
      tc(%W[qdisc delete root dev #{veth}], valid_rcs: [2])
      tc(%W[qdisc add root dev #{veth} cake bandwidth #{max_rx}bit])
    end

    def unset_shaper_rx
      tc(%W[qdisc delete root dev #{veth}], valid_rcs: [2])
    end

    def set_shaper_tx
      NetInterface.sync_host_link_registry do
        veth_name, veth_ifindex, recorded_ifb_ifindex =
          validate_down_callback
        unless veth_name
          raise InvalidHostLink, 'cannot configure IFB without a recorded host veth'
        end

        if host_link_tainted?
          raise InvalidHostLink,
                "host veth #{veth_name.inspect} is cleanup-tainted; " \
                'complete recorded link deletion before configuring its IFB'
        end

        validate_live_host_link!(
          veth_name,
          veth_ifindex,
          expected_kind: 'veth'
        )

        ifb_name = "ifb#{veth_name}"
        validate_unshared_host_link!(
          veth_name,
          veth_ifindex,
          recorded_ifb_ifindex,
          ifb_name:
        )
        ifb_exists = Dir.exist?("/sys/devices/virtual/net/#{ifb_name}")

        if ifb_exists && !recorded_ifb_ifindex
          raise InvalidHostLink,
                "host IFB #{ifb_name.inspect} exists without a recorded identity"
        elsif !ifb_exists && recorded_ifb_ifindex
          raise InvalidHostLink,
                "recorded host IFB #{ifb_name.inspect} " \
                "(ifindex #{recorded_ifb_ifindex}) is absent"
        end

        created_ifb = !ifb_exists
        unless ifb_exists
          ip(:all, %W[link add name #{ifb_name} type ifb])
        end

        live_ifb_ifindex = host_veth_ifindex!(ifb_name, expected_kind: 'ifb')
        if recorded_ifb_ifindex && recorded_ifb_ifindex != live_ifb_ifindex
          raise InvalidHostLink,
                "host IFB #{ifb_name.inspect} changed from ifindex " \
                "#{recorded_ifb_ifindex} to #{live_ifb_ifindex}"
        end

        # Persist newly created deletion authority before any later check or
        # traffic-control operation can fail. If the allocated ifindex
        # conflicts with a stale daemon claim, recovery must never be left
        # with an unrecorded IFB.
        exclusively { @ifb_ifindex = live_ifb_ifindex }
        persist_host_link_state

        begin
          validate_unshared_host_link!(
            veth_name,
            veth_ifindex,
            live_ifb_ifindex,
            ifb_name:
          )
        rescue StandardError => e
          if created_ifb
            rollback_created_ifb!(
              live_ifb_ifindex,
              ifb_name,
              e
            )
          end
          raise
        end

        unless ifb_exists
          tc(%W[qdisc del dev #{veth} ingress], valid_rcs: [2])
          tc(%W[qdisc add dev #{veth} handle ffff: ingress])
        end

        tc(%W[qdisc del dev #{ifb_name} root], valid_rcs: [2])
        tc(%W[qdisc add dev #{ifb_name} root cake bandwidth #{max_tx}bit besteffort])
        return if ifb_exists

        ip(:all, %W[link set #{ifb_name} up])
        tc(%W[filter add dev #{veth} parent ffff: matchall action mirred egress redirect dev #{ifb_name}])
      rescue StandardError
        taint_host_link!
        raise
      end
    end

    def unset_shaper_tx
      NetInterface.sync_host_link_registry do
        veth_name, veth_ifindex, ifb_ifindex = validate_down_callback
        return unless ifb_ifindex

        validate_live_host_link!(
          veth_name,
          veth_ifindex,
          expected_kind: 'veth'
        )
        validate_live_host_link!(
          "ifb#{veth_name}",
          ifb_ifindex,
          expected_kind: 'ifb'
        )
        tc(%W[filter delete dev #{veth} parent ffff:])
        tc(%W[qdisc delete dev #{veth} handle ffff: ingress])

        delete_recorded_host_link!(ifb_ifindex, "ifb#{veth_name}", 'ifb')
        exclusively { @ifb_ifindex = nil }
        persist_host_link_state
      rescue StandardError
        taint_host_link!
        raise
      end
    end

    def delete_recorded_host_link!(ifindex, expected_name, expected_kind)
      delete_link_by_ifindex(
        ifindex,
        expected_name:,
        expected_kind:
      )
    rescue Utils::Ip::LinkIdentityError => e
      raise InvalidHostLink, e.message
    rescue Errno::ENODEV
      raise InvalidHostLink,
            "recorded network interface #{expected_name.inspect} " \
            "(ifindex #{ifindex}, kind #{expected_kind.inspect}) disappeared before deletion"
    end

    def load_host_link(cfg)
      unless cfg
        @veth = nil
        @veth_ifindex = nil
        @ifb_ifindex = nil
        @host_link_boot_id = nil
        @host_link_tainted = false
        return
      end

      raise InvalidHostLink, 'persisted host-link identity is not a map' unless cfg.is_a?(Hash)

      current_boot_id = self.class.current_host_boot_id
      boot_id = cfg['boot_id']
      if boot_id && (
        !boot_id.is_a?(String) || !HOST_BOOT_ID_PATTERN.match?(boot_id)
      )
        raise InvalidHostLink,
              "persisted host-link boot ID #{boot_id.inspect} is invalid"
      end

      if boot_id && boot_id != current_boot_id
        @veth = nil
        @veth_ifindex = nil
        @ifb_ifindex = nil
        @host_link_boot_id = nil
        @host_link_tainted = false
        @setup_state_changed = true
        return
      end

      veth_name = validate_kernel_ifname(cfg['name'])
      veth_ifindex = cfg['ifindex']
      ifb_ifindex = cfg['ifb_ifindex']
      tainted = cfg.fetch('tainted', false)

      unless veth_ifindex.is_a?(Integer) && veth_ifindex > 0
        raise InvalidHostLink,
              "persisted host veth #{veth_name.inspect} has invalid ifindex " \
              "#{veth_ifindex.inspect}"
      end
      if ifb_ifindex && (!ifb_ifindex.is_a?(Integer) || ifb_ifindex <= 0)
        raise InvalidHostLink,
              "persisted host veth #{veth_name.inspect} has invalid IFB ifindex " \
              "#{ifb_ifindex.inspect}"
      end
      if ifb_ifindex == veth_ifindex
        raise InvalidHostLink,
              "persisted host veth #{veth_name.inspect} reuses ifindex " \
              "#{veth_ifindex} for its IFB"
      end
      unless [true, false].include?(tainted)
        raise InvalidHostLink,
              "persisted host veth #{veth_name.inspect} has invalid taint " \
              "#{tainted.inspect}"
      end

      @veth = veth_name
      @veth_ifindex = veth_ifindex
      @ifb_ifindex = ifb_ifindex
      @host_link_boot_id = boot_id || current_boot_id
      @host_link_tainted = tainted
      @setup_state_changed = true unless boot_id
    end

    def persist_host_link_state
      ct.save_config
    end

    def taint_host_link_on_setup!
      NetInterface.sync_host_link_registry do
        exclusively do
          next false unless @veth

          @host_link_tainted = true
          @setup_state_changed = true
        end
      end
    end

    def taint_host_link!
      NetInterface.sync_host_link_registry do
        changed = exclusively do
          next false unless @veth
          next false if @host_link_tainted

          @host_link_tainted = true
          true
        end
        return unless changed

        ct.state = :error
        persist_host_link_state
      end
    end

    def validate_live_host_link!(name, ifindex, expected_kind:)
      live_ifindex = host_veth_ifindex!(name, expected_kind:)
      return live_ifindex if live_ifindex == ifindex

      raise InvalidHostLink,
            "host network interface #{name.inspect} " \
            "(kind #{expected_kind.inspect}) changed from ifindex " \
            "#{ifindex} to #{live_ifindex}"
    end

    def rollback_created_ifb!(ifindex, name, claim_error)
      delete_recorded_host_link!(ifindex, name, 'ifb')
      exclusively { @ifb_ifindex = nil }
      persist_host_link_state
    rescue StandardError => e
      raise InvalidHostLink,
            "#{claim_error.message}; unable to roll back newly created IFB " \
            "#{name.inspect} (ifindex #{ifindex}): " \
            "#{e.class}: #{e.message}"
    end

    def validate_unshared_host_link!(
      name,
      veth_ifindex,
      ifb_ifindex,
      ifb_name:
    )
      NetInterface.validate_host_link_claim!(
        owner_ct: ct,
        owner_netif: self,
        name:,
        veth_ifindex:,
        ifb_ifindex:,
        ifb_name:
      )
    rescue NetInterface::HostLinkClaimError => e
      raise InvalidHostLink, e.message
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
