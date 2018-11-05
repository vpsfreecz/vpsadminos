require 'osctld/commands/base'

module OsCtld
  class Commands::Container::Mount < Commands::Base
    handle :ct_mount

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct

      manipulate(ct) { ct.mount(force: true) }
      ok
    end
  end
end
