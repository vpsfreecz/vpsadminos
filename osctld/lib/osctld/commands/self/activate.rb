require 'osctld/commands/base'
require 'etc'

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

        nproc = Etc.nprocessors
        ep = ExecutionPlan.new

        DB::Containers.get.each do |ct|
          ep << ct
        end

        ep.run([nproc / 2, 1].max) do |ct|
          next unless ct.running?

          begin
            ct_syscmd(ct, %w(cat /proc/stat /proc/loadavg), valid_rcs: :all)
          rescue SystemCommandFailed
            # pass
          end
        end

        ep.wait
      end

      ok
    end
  end
end
