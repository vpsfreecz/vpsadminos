require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::CGParamUnset < Commands::Logged
    handle :ct_cgparam_unset
    include Utils::CGroupParams

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      unset(ct, opts, reset: true, keep_going: true)
    end
  end
end
