require 'osctld/commands/base'

module OsCtld
  class Commands::Daemon::WaitReady < Commands::Base
    handle :daemon_wait_ready

    def execute
      timeout = opts.fetch(:timeout, Daemon.get.config.restart.recovery_timeout)

      if Daemon.get.wait_ready(timeout:)
        ok(Daemon.get.status)
      else
        error("daemon did not become ready within #{timeout} seconds")
      end
    end
  end
end
