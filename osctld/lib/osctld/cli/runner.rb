require 'libosctl'
require 'json'
require 'socket'
require 'osctld/container_control/result'

module OsCtld
  class Cli::Runner
    def self.run
      ret = nil

      unless ARGV.empty?
        warn "Usage: #{$0}"
        exit(false)
      end

      begin
        cfg = JSON.parse($stdin.readline, symbolize_names: true)
        ret = IO.new(cfg[:return])
        ret.close_on_exec = true

        OsCtl::Lib::Logger.setup(:none)
        CGroup.init

        Process.setproctitle(
          "osctld: #{cfg[:pool]}:#{cfg[:id]} runner:#{cfg[:name].downcase}"
        )

        stdin = cfg[:stdin] && IO.new(cfg[:stdin])
        stdout = IO.new(cfg[:stdout])
        stderr = IO.new(cfg[:stderr])
        network_socket = cfg[:network_socket] && UNIXSocket.for_fd(cfg[:network_socket])
        network_socket.close_on_exec = true if network_socket

        [stdin, stdout, stderr].compact.each do |io|
          io.close_on_exec = true
        end

        runner = OsCtld::ContainerControl::Commands.const_get(cfg[:name])::Runner.new(
          pool: cfg[:pool],
          id: cfg[:id],
          lxc_home: cfg[:lxc_home],
          user_home: cfg[:user_home],
          log_file: cfg[:log_file],
          stdin:,
          stdout:,
          stderr:,
          network_socket:
        )
      rescue StandardError => e
        report_failure(ret, e, :setup)
      end

      begin
        val = runner.execute(*cfg[:args], **cfg[:kwargs])
      rescue StandardError => e
        report_failure(ret, e, :execution)
      end

      begin
        ret.puts(val.to_json)
      rescue StandardError => e
        report_failure(ret, e, :response)
      end
    end

    def self.report_failure(ret, error, stage)
      payload = ContainerControl::Result.failure_payload(error, stage:)

      begin
        if ret
          ret.puts(payload.to_json)
        else
          warn payload[:diagnostic]
        end
      rescue SystemCallError, IOError
        # This is the daemon supervisor's stderr, not the command's stderr.
        warn payload[:diagnostic]
      end
      exit(false)
    end

    private_class_method :report_failure
  end
end
