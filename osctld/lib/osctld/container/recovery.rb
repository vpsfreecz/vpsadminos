require 'libosctl'

module OsCtld
  # Contains method to work with an unresponsive or dead containers
  class Container::Recovery
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

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

      if orig_state == current_state
        return

      elsif current_state == :stopped
        # Put all network interfaces down
        ct.netifs.take_down

        # Unload AppArmor profile and destroy namespace
        ct.apparmor.destroy_namespace
        ct.apparmor.unload_profile

        ct.stopped

        # User-defined hook
        Hook.run(ct, :post_stop)

        # Announce the change first as :aborting, that will cause a waiting
        # osctl ct start to give it up
        Eventd.report(:state, pool: ct.pool.name, id: ct.id, state: :aborting)
        Eventd.report(:state, pool: ct.pool.name, id: ct.id, state: :stopped)

      else
        # Announce the change
        Eventd.report(:state, pool: ct.pool.name, id: ct.id, state: change[:state])
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

        if ctid[0] == ct.pool.name && ctid[1] == ct.id
          log(:info, "kill -SIG#{signal} #{p.pid} #{p.name}")

          begin
            Process.kill(signal, p.pid)
          rescue Errno::ESRCH
          end
        end
      end
    end

    # Cleanup after the container or put the container into an error state
    # @return [Boolean]
    def cleanup_or_taint
      taint = false

      begin
        cleanup_cgroups
      rescue => e
        log(:warn, "Failed to cleanup cgroups: #{e.class}: #{e.message}")
        taint = true
      end

      begin
        cleanup_netifs
      rescue => e
        log(:warn, "Failed to cleanup netifs: #{e.class}: #{e.message}")
        taint = true
      end

      ct.state = :error if taint
      !taint
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
      # name => routes
      veths = {}

      [4, 6].each do |ip_v|
        routes = RouteList.new(ip_v)

        ct.netifs.each do |netif|
          next if netif.type != :routed

          netif.routes.each_version(ip_v) do |route|
            veth = routes.veth_of(route)

            if veth
              log(:info, "Found route #{route.addr.to_string} on #{veth}")
              veths[veth] = [] unless veths.has_key?(veth)
              veths[veth] << route
            end
          end
        end
      end

      veths.each do |veth, routes|
        found = DB::Containers.get.detect do |ct|
          n = ct.netifs.detect do |netif|
            netif.respond_to?(:veth) && netif.veth == veth
          end
          n && ct
        end

        if found
          log(:info, "Interface #{veth} is used by container #{found.ident}")
        else
          yield(veth, routes) if block_given?
          log(:info, "Removing #{veth}")
          syscmd("ip link delete #{veth}")
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

        JSON.parse(syscmd("ip -#{ip_v} -json route list").output).each do |route|
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
        if route.addr.ipv4? && route.addr.prefix == 32
          route.addr.to_s
        elsif route.addr.ipv6? && route.addr.prefix == 128
          route.addr.to_s
        else
          route.addr.to_string
        end
      end
    end

    protected
    attr_reader :ct
  end
end
