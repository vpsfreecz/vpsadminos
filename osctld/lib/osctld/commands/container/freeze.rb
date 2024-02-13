require 'osctld/commands/base'

module OsCtld
  class Commands::Container::Freeze < Commands::Base
    handle :ct_freeze

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      manipulate(ct) do
        if %i[freezing frozen stopped].include?(ct.state)
          next ok
        end

        ContainerControl::Commands::Freeze.run!(ct)
        ok
      end
    end
  end
end
