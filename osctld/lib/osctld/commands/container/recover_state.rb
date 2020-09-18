require 'osctld/commands/base'

module OsCtld
  class Commands::Container::RecoverState < Commands::Base
    handle :ct_recover_state

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      manipulate(ct) do
        recovery = Container::Recovery.new(ct)
        recovery.recover_state
        ok
      end
    end
  end
end
