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

      manipulate(ct, lifecycle: true) do
        recovery = Container::Recovery.new(ct)
        ret = recovery.cleanup(
          run_id: opts[:run_id],
          cleanup: opts[:cleanup],
          force: opts[:force],
          admission: {}
        ) do |veth, routes|
          progress(
            "#{veth}: " + routes.map do |route|
              route.respond_to?(:addr) ? route.addr.to_string : route.to_s
            end.join(' ')
          )
        end

        if %i[blocked ambiguous].include?(ret[:outcome])
          error(ret.to_json)
        else
          progress(ret[:hazards].join('; ')) if ret[:hazards].any?
          ok(ret)
        end
      end
    rescue ArgumentError => e
      error(e.message)
    end
  end
end
