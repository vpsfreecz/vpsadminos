require 'osctld/commands/base'

module OsCtld
  class Commands::Container::Reconfigure < Commands::Base
    handle :ct_reconfigure

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      manipulate(ct) do
        ct.configure_lxc
        ok
      end
    end
  end
end
