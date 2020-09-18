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
        if ct.state != :stopped && !opts[:force]
          error!('the container has to be stopped')
        end

        recovery = Container::Recovery.new(ct)

        if opts[:cleanup] == 'all' || opts[:cleanup].include?('cgroups')
          recovery.cleanup_cgroups
        end

        if opts[:cleanup] == 'all' || opts[:cleanup].include?('netifs')
          progress('Searching for stray network interfaces')

          recovery.cleanup_netifs do |veth, routes|
            progress(
              "#{veth}: "+(routes.map{ |v| v.addr.to_string}.join(' '))
            )
          end
        end

        ok
      end
    end
  end
end
