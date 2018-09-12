require 'osctld/commands/base'

module OsCtld
  class Commands::Container::CGParamReplace < Commands::Base
    handle :ct_cgparam_replace

    include OsCtl::Lib::Utils::Log
    include Utils::CGroupParams

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      replace(ct)
    end
  end
end
