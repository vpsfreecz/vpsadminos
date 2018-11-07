require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::ConfigReplace < Commands::Logged
    handle :ct_cfg_replace

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      manipulate(ct) do
        error!('the container has to be stopped') if ct.current_state != :stopped

        ct.replace_config(opts[:config])
        ct.lxc_config.configure
      end

      progress('Reconfiguring LXC usernet')
      call_cmd(Commands::User::LxcUsernet)

      ok
    end
  end
end
