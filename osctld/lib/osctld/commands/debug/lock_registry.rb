require 'osctld/commands/base'

module OsCtld
  class Commands::Debug::LockRegistry < Commands::Base
    handle :debug_lock_registry

    def execute
      ok(LockRegistry.export)
    end
  end
end
