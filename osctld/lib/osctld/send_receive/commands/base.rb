require 'osctld/commands/base'

module OsCtld
  class SendReceive::Commands::Base < OsCtld::Commands::Base
    def self.handle(name)
      SendReceive::Command.register(name, self)
    end

    def base_execute
      validate_protocol_version!
      execute
    end

    protected

    def validate_protocol_version!
      return if SendReceive.supported_protocol_version?(opts[:protocol_version])

      error!(SendReceive.protocol_error(opts[:protocol_version]))
    end

    def validate_send_log_protocol!(ct)
      return if ct.send_log&.protocol_version == opts[:protocol_version]

      error!(
        'send/receive protocol version mismatch, ' \
        "request=#{opts[:protocol_version]} log=#{ct.send_log&.protocol_version.inspect}"
      )
    end

    def receive_pipeline_error(mbuffer_status, recv_status)
      failures = []
      failures << "mbuffer exited with #{mbuffer_status.exitstatus}" if mbuffer_status.exitstatus != 0
      failures << "zfs recv exited with #{recv_status.exitstatus}" if recv_status.exitstatus != 0
      "unable to receive stream, #{failures.join(' and ')}"
    end
  end
end
