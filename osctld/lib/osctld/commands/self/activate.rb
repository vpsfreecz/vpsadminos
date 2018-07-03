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

      if opts[:lxcfs]
        progress('Refreshing LXCFS')
        DB::Containers.get.each do |ct|
          ct.inclusively do
            next unless ct.running?

            begin
              ct_syscmd(ct, 'cat /proc/stat', valid_rcs: :all)
              ct_syscmd(ct, 'cat /proc/loadavg', valid_rcs: :all)

            rescue SystemCommandFailed
              # pass
            end
          end
        end
      end

      ok
    end
  end
end
