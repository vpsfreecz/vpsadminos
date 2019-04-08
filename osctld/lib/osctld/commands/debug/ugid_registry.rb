require 'libosctl'
require 'osctld/commands/base'

module OsCtld
  class Commands::Debug::UGidkRegistry < Commands::Base
    handle :debug_ugid_registry

    include OsCtl::Lib::Utils::Exception

    def execute
      ok(UGidRegistry.export)
    end
  end
end
