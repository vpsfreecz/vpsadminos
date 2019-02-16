require 'json'
require 'osctld/commands/base'

module OsCtld
  class Commands::Container::RecoverCleanup < Commands::Base
    handle :ct_recover_cleanup

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      manipulate(ct) do
        error!('the container has to be stopped') if ct.state != :stopped

        progress('Removing leftover cgroups')
        CGroup.rmpath_all(File.join(ct.cgroup_path, 'lxc'))

        progress('Searching for stray network interfaces')
        veths = []

        [4, 6].each do |ip_v|
          routes = RouteList.new(ip_v)

          ct.netifs.each do |netif|
            next if netif.type != :routed

            netif.routes.each_version(ip_v) do |route|
              veth = routes.veth_of(route)

              if veth
                progress("Found route #{route.addr.to_string} on #{veth}")
                veths << veth unless veths.include?(veth)
              end
            end
          end
        end

        veths.each do |veth|
          found = DB::Containers.get.detect do |ct|
            n = ct.netifs.detect do |netif|
              netif.respond_to?(:veth) && netif.veth == veth
            end
            n && ct
          end

          if found
            progress("Interface #{veth} is used by container #{found.ident}")
          else
            progress("Removing #{veth}")
            syscmd("ip link delete #{veth}")
          end
        end

        ok
      end
    end

    protected
    class RouteList
      include OsCtl::Lib::Utils::Log
      include OsCtl::Lib::Utils::System

      # @param ip_v [Integer]
      def initialize(ip_v)
        @index = {}

        JSON.parse(syscmd("ip -#{ip_v} -json route list")[:output]).each do |route|
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
          route.addr.to_string
        else
          fail 'programming error'
        end
      end
    end
  end
end
