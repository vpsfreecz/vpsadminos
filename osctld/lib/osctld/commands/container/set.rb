module OsCtld
  class Commands::Container::Set < Commands::Base
    handle :ct_set

    include Utils::Log
    include Utils::System

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ct.exclusively do
        ct.set(nesting: opts[:nesting]) if opts[:nesting] != ct.nesting
        ok
      end
    end
  end
end
