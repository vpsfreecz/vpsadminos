require 'libosctl'
require 'osctld/container/run_configuration'
require 'osctld/utils/ip'

module OsCtld
  # Contains method to work with an unresponsive or dead containers
  class Container::Recovery
    class InvalidNetifIdentity < StandardError; end

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::Ip

    # @param ct [Container]
    def initialize(ct)
      @ct = ct
    end

    # Rediscover container state
    #
    # If the container is found dead, appropriate actions and hooks
    # for container stop are run.
    def recover_state
      orig_state = ct.state
      current_state = ct.current_state
      netif_cleanup_failed = false

      if orig_state == current_state
        # do nothing

      elsif current_state == :stopped
        run_conf, run_lease = lease_current_run

        if run_lease
          teardown_failures = []
          ct.stopped(run_conf) do |teardown_owner|
            begin
              # Put all network interfaces down
              begin
                take_down_netifs
              rescue StandardError => e
                log(:warn, "Failed to take down netifs: #{e.class}: #{e.message}")
                netif_cleanup_failed = true
              end
            ensure
              # Recovery's network cleanup is path-specific and must complete
              # even when authenticated post-stop owns the common teardown.
              run_lease.close
              run_lease = nil
            end

            next unless teardown_owner

            # Retirement rejects new leases. Wait for every already-admitted
            # path-specific effect before running common teardown effects.
            capture_teardown_failure(teardown_failures, :lifecycle_leases) do
              run_conf.wait_for_lifecycle_leases
            end

            if AppArmor.enabled?
              capture_teardown_failure(teardown_failures, :apparmor_namespace) do
                ct.apparmor.destroy_namespace
              end
              capture_teardown_failure(teardown_failures, :apparmor_profile) do
                ct.apparmor.unload_profile
              end
            end

            capture_teardown_failure(teardown_failures, :post_stop_hook) do
              Hook.run(ct, :post_stop)
            end
          end

          raise_teardown_failure(teardown_failures)
        end

        # Announce the change first as :aborting, that will cause a waiting
        # osctl ct start to give it up
        Eventd.report(:state, pool: ct.pool.name, id: ct.id, state: :aborting)
        Eventd.report(:state, pool: ct.pool.name, id: ct.id, state: :stopped)

      else
        # Announce the change
        Eventd.report(:state, pool: ct.pool.name, id: ct.id, state: current_state)
      end

      Eventd.report(:state_recovery, pool: ct.pool.name, id: ct.id, state: current_state)
      nil
    ensure
      begin
        run_lease&.close
      ensure
        cleanup_or_taint if netif_cleanup_failed
      end
    end

    # Kill all processes found in the container's cgroup with signal
    # @param signal [String]
    def kill_all(signal: 'KILL')
      pl = OsCtl::Lib::ProcessList.new do |p|
        ctid = p.ct_id
        next(false) if ctid.nil?

        ctid[0] == ct.pool.name && ctid[1] == ct.id
      end

      log(:info, "#{pl.length} processes to kill")
      pl.each do |p|
        # Double check
        ctid = p.ct_id
        next if ctid.nil?

        next unless ctid[0] == ct.pool.name && ctid[1] == ct.id

        log(:info, "kill -SIG#{signal} #{p.pid} #{p.name}")

        begin
          Process.kill(signal, p.pid)
        rescue Errno::ESRCH
          # ignore
        end
      end
    end

    # Cleanup after the container or put the container into an error state
    # @return [Boolean]
    def cleanup_or_taint
      taint = false

      begin
        cleanup_cgroups
      rescue StandardError => e
        log(:warn, "Failed to cleanup cgroups: #{e.class}: #{e.message}")
        taint = true
      end

      begin
        take_down_netifs
      rescue StandardError => e
        log(:warn, "Failed to take down netifs: #{e.class}: #{e.message}")
        taint = true
      end

      begin
        cleanup_netifs
      rescue StandardError => e
        log(:warn, "Failed to cleanup netifs: #{e.class}: #{e.message}")
        taint = true
      end

      begin
        NetInterface.sync_host_link_registry do
          NetInterface.validate_container_host_links_released!(ct)
        end
      rescue StandardError => e
        log(:warn, "Failed to verify released host links: #{e.class}: #{e.message}")
        taint = true
      end

      if taint
        ct.state = :error
        ct.save_config
      elsif ct.state == :error
        # A complete retry is the deliberate transition that clears a durable
        # recovery taint. Individual callbacks cannot make an errored container
        # startable merely by replaying an up event.
        ct.state = :stopped
        ct.save_config
      end
      !taint
    end

    # Pin the current run while holding the container pointer lock. A run that
    # has already begun retirement is being cleaned by another owner and must
    # not be touched without a lease.
    def lease_current_run
      run_conf = nil
      lease = nil

      ct.inclusively do
        run_conf = ct.run_conf
        lease = run_conf&.acquire_lifecycle_lease
      end

      [run_conf, lease]
    rescue Container::RunConfiguration::LifecycleError
      [run_conf, nil]
    end

    # Remove left-over cgroups in container path
    def cleanup_cgroups
      CGroup.rmpath_all(File.join(ct.cgroup_path, "lxc.payload.#{ct.id}"))
      CGroup.rmpath_all(File.join(ct.cgroup_path, "lxc.monitor.#{ct.id}"))
      CGroup.rmpath_all(File.join(ct.cgroup_path, "lxc.pivot.#{ct.id}"))
    end

    # Find and remove left-over network interfaces used by the container
    # @yieldparam veth [String]
    # @yieldparam routes [Array<Routing::Route>]
    def cleanup_netifs
      # discovered name => exact configured netif and routes
      veths = {}

      [4, 6].each do |ip_v|
        routes = RouteList.new(ip_v)

        ct.netifs.each do |netif|
          next if netif.type != :routed

          netif.routes.each_version(ip_v) do |route|
            veth = routes.veth_of(route)

            next unless veth

            log(:info, "Found route #{route.addr.to_string} on #{veth}")
            entry = veths[veth]
            if entry && !entry[:netif].equal?(netif)
              raise InvalidNetifIdentity,
                    "host veth #{veth.inspect} is associated with multiple routed netifs"
            end

            entry ||= (veths[veth] = { netif:, routes: [] })
            entry[:routes] << route
          end
        end
      end

      NetInterface.sync_host_link_registry do
        veths.each do |discovered_name, entry|
          _recorded_name, veth_ifindex, ifb_ifindex = validate_recovery_identity(
            entry[:netif],
            discovered_name
          )
          validate_unshared_recovery_identity(
            discovered_name,
            veth_ifindex,
            ifb_ifindex,
            owner_netif: entry[:netif]
          )

          yield(discovered_name, entry[:routes]) if block_given?
          log(:info, "Removing #{discovered_name} (ifindex #{veth_ifindex})")
          # The netif owns both the kernel mutation and its durable identity.
          # Delegating cleanup ensures an IFB deletion is persisted before the
          # veth attempt and a completed deletion clears the record atomically
          # from recovery's point of view.
          entry[:netif].down(discovered_name)
        end
      end
    end

    def log_type
      "recover=#{ct.pool.name}:#{ct.id}"
    end

    class RouteList
      include OsCtl::Lib::Utils::Log
      include OsCtl::Lib::Utils::System

      # @param ip_v [Integer]
      def initialize(ip_v)
        @index = {}

        JSON.parse(syscmd_argv(['ip', "-#{ip_v}", '-json', 'route', 'list']).output).each do |route|
          next unless route['dev'].start_with?('veth')

          index[route['dst']] = route['dev']
        end
      end

      # @param route [Routing::Route]
      def veth_of(route)
        index[key(route)]
      end

      protected

      attr_reader :index

      def key(route)
        if (route.addr.ipv4? && route.addr.prefix == 32) \
            || (route.addr.ipv6? && route.addr.prefix == 128)
          route.addr.to_s
        else
          route.addr.to_string
        end
      end
    end

    protected

    attr_reader :ct

    def take_down_netifs
      # Freeze both the daemon container set and all runtime host-link record
      # mutations from the first all-record check through the final delegated
      # deletion. A clone from DB::Containers.get alone is not a stable
      # authority snapshot.
      NetInterface.sync_host_link_registry do
        preflight_netif_cleanup
        ct.netifs.take_down
      end
    end

    # Validate every recorded link owned by this container against all daemon
    # records before direct teardown can mutate any of them.
    def preflight_netif_cleanup
      ct.netifs.each do |netif|
        next unless netif.respond_to?(:host_link_identity)

        recorded_identity = netif.host_link_identity
        recorded_name, veth_ifindex, ifb_ifindex = recorded_identity
        next if recorded_name.nil? && veth_ifindex.nil? && ifb_ifindex.nil?

        recorded_name, veth_ifindex, ifb_ifindex = validate_recovery_identity(
          netif,
          recorded_name,
          recorded_identity:
        )
        validate_unshared_recovery_identity(
          recorded_name,
          veth_ifindex,
          ifb_ifindex,
          owner_netif: netif
        )
      end
    end

    def validate_recovery_identity(netif, discovered_name, recorded_identity: nil)
      unless netif.respond_to?(:host_link_identity)
        raise InvalidNetifIdentity,
              "netif for #{discovered_name.inspect} has no recorded host-link identity"
      end

      recorded_name, veth_ifindex, ifb_ifindex =
        recorded_identity || netif.host_link_identity
      unless recorded_name.is_a?(String) && !recorded_name.empty?
        raise InvalidNetifIdentity,
              "netif for #{discovered_name.inspect} has no recorded host-veth name"
      end
      if recorded_name != discovered_name
        raise InvalidNetifIdentity,
              "discovered host veth #{discovered_name.inspect} does not match " \
              "recorded #{recorded_name.inspect}"
      end
      unless veth_ifindex.is_a?(Integer) && veth_ifindex > 0
        raise InvalidNetifIdentity,
              "host veth #{recorded_name.inspect} has no valid recorded ifindex"
      end
      if ifb_ifindex && (!ifb_ifindex.is_a?(Integer) || ifb_ifindex <= 0)
        raise InvalidNetifIdentity,
              "host veth #{recorded_name.inspect} has invalid recorded IFB ifindex " \
              "#{ifb_ifindex.inspect}"
      end
      if ifb_ifindex == veth_ifindex
        raise InvalidNetifIdentity,
              "host veth #{recorded_name.inspect} reuses ifindex #{veth_ifindex} for its IFB"
      end

      [recorded_name, veth_ifindex, ifb_ifindex]
    end

    def validate_unshared_recovery_identity(
      name,
      veth_ifindex,
      ifb_ifindex,
      owner_netif:
    )
      NetInterface.validate_host_link_claim!(
        owner_ct: ct,
        owner_netif:,
        name:,
        veth_ifindex:,
        ifb_ifindex:,
        ifb_name: ifb_ifindex && "ifb#{name}"
      )
    rescue NetInterface::HostLinkClaimError => e
      raise InvalidNetifIdentity, e.message
    end

    def capture_teardown_failure(failures, step)
      yield
    rescue StandardError => e
      failures << [step, e]
    end

    def raise_teardown_failure(failures)
      return if failures.empty?

      failures.drop(1).each do |step, error|
        log(:warn, "Additional #{step} teardown failure: #{error.class}: #{error.message}")
      rescue StandardError
        # Preserve the first teardown error even if secondary logging fails.
      end

      raise failures.first.last
    end
  end
end
