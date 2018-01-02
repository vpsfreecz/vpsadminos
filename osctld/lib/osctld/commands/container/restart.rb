module OsCtld
  class Commands::Container::Restart < Commands::Base
    handle :ct_restart

    include Utils::Log
    include Utils::System
    include Utils::SwitchUser

    def execute
      ct = DB::Containers.find(opts[:id]) || (raise 'container not found')
      ct.exclusively do
        call_cmd(Commands::Container::Stop, id: ct.id)
        call_cmd(Commands::Container::Start, id: ct.id)
      end
    end
  end
end
