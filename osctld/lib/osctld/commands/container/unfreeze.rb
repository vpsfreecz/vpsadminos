require 'osctld/commands/base'

module OsCtld
  class Commands::Container::Unfreeze < Commands::Base
    handle :ct_unfreeze

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      manipulate(ct) do
        if %i(thawed starting running stopping stopped).include?(ct.state)
          next ok
        end

        ContainerControl::Commands::Unfreeze.run!(ct)
        ok
      end
    end
  end
end
