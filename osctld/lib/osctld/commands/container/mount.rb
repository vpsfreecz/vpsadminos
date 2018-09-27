require 'osctld/commands/base'

module OsCtld
  class Commands::Container::Mount < Commands::Base
    handle :ct_mount

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct

      ct.exclusively do
        ct.mount(force: true)
      end

      ok
    end
  end
end
