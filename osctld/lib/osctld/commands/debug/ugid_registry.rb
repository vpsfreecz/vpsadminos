require 'libosctl'
require 'osctld/commands/base'

module OsCtld
  class Commands::Debug::UGidRegistry < Commands::Base
    handle :debug_ugid_registry

    include OsCtl::Lib::Utils::Exception

    def execute
      ok(UGidRegistry.export)
    end
  end
end
