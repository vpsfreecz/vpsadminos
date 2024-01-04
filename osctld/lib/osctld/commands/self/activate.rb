require 'osctld/commands/base'

module OsCtld
  class Commands::Self::Activate < Commands::Base
    handle :self_activate

    include OsCtl::Lib::Utils::Log
    include Utils::SwitchUser

    def execute
      if opts[:system]
        progress('Regenerating system files')
        call_cmd(Commands::User::SubUGIds)
        call_cmd(Commands::User::LxcUsernet)
      end

      ok
    end
  end
end
