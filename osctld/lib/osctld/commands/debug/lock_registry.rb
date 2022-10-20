require 'libosctl'
require 'osctld/commands/base'

module OsCtld
  class Commands::Debug::LockRegistry < Commands::Base
    handle :debug_lock_registry

    include OsCtl::Lib::Utils::Exception

    def execute
      error!('lock registry is disabled') unless LockRegistry.enabled?

      ok(LockRegistry.export.each do |lock|
        lock[:backtrace] = denixstorify(lock[:backtrace])
        lock
      end)
    end
  end
end
