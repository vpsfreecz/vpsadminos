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

        ep = ExecutionPlan.new

        DB::Containers.get.each do |ct|
          ep << ct
        end

        ep.run do |ct|
          next unless ct.running?

          begin
            ContainerControl::Commands::ActivateLxcfs.run!(ct)
          rescue ContainerControl::Error
            # pass
          end
        end

        ep.wait
      end

      ok
    end
  end
end
