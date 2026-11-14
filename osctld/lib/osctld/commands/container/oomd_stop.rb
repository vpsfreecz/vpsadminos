require 'osctld/commands/container/stop'
require 'osctld/commands/container/oomd_guard'

module OsCtld
  class Commands::Container::OomdStop < Commands::Container::Stop
    handle :ct_oomd_stop

    def execute(ct)
      with_oomd_run(ct) do
        @opts = opts.merge(method: 'kill')
        super
      end
    end

    include Commands::Container::OomdGuard
  end
end
