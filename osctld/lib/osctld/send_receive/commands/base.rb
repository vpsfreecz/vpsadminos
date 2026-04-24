require 'osctld/commands/base'

module OsCtld
  class SendReceive::Commands::Base < OsCtld::Commands::Base
    def self.handle(name)
      SendReceive::Command.register(name, self)
    end

    protected

    def receive_pipeline_error(mbuffer_status, recv_status)
      failures = []
      failures << "mbuffer exited with #{mbuffer_status.exitstatus}" if mbuffer_status.exitstatus != 0
      failures << "zfs recv exited with #{recv_status.exitstatus}" if recv_status.exitstatus != 0
      "unable to receive stream, #{failures.join(' and ')}"
    end
  end
end
