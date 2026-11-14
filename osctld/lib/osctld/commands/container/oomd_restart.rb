require 'osctld/commands/container/restart'
require 'osctld/commands/container/oomd_guard'

module OsCtld
  class Commands::Container::OomdRestart < Commands::Container::Restart
    handle :ct_oomd_restart

    def execute(ct)
      with_oomd_run(ct) do
        @opts = opts.merge(stop_method: 'kill', reboot: false)
        super
      end
    end

    include Commands::Container::OomdGuard
  end
end
