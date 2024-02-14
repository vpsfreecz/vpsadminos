require 'libosctl'
require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'

module OsCtld
  # Execute command within a container and return its output
  class ContainerControl::Commands::Syscmd < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      # @param cmd [Array<String>] command to execute
      # @param opts [Hash] options
      # @option opts [IO, String] :stdin
      # @option opts [Boolean] :run run the container if it is stopped?
      # @option opts [Boolean] :network setup network if the container is run?
      # @option opts [Array<Integer>, Symbol] :valid_rcs
      # @return [OsCtl::Lib::SystemCommandResult]
      # @raise [OsCtld::SystemCommandFailed]
      def execute(cmd, opts = {})
        opts[:valid_rcs] ||= []

        in_r, in_w = nil
        out_r, out_w = IO.pipe

        if opts[:stdin].is_a?(String)
          in_r, in_w = IO.pipe
          in_w.write(opts[:stdin])
          in_w.close

        elsif opts[:stdin]
          in_r = opts[:stdin]
        end

        if !ct.running? && !opts[:run]
          raise OsCtld::SystemCommandFailed.new(cmd, 1, 'Container is not running')
        end

        begin
          ret = ContainerControl::Commands::Exec.run!(
            ct,
            cmd:,
            stdin: in_r,
            stdout: out_w,
            stderr: out_w,
            run: opts[:run],
            network: opts[:network]
          )
        rescue ContainerControl::Error => e
          out_r.close
          raise OsCtld::SystemCommandFailed.new(
            cmd,
            1,
            "Command '#{cmd}' within CT #{ct.id} failed: #{e.message}"
          )
        ensure
          in_r.close if in_r && opts[:stdin].is_a?(String)
          out_w.close
        end

        out = out_r.read
        out_r.close

        if ret != 0 &&
           opts[:valid_rcs] != :all &&
           !opts[:valid_rcs].include?(ret)
          raise OsCtld::SystemCommandFailed.new(
            cmd,
            1,
            "Command '#{cmd}' within CT #{ct.id} failed with exit code " \
            "#{ret}: #{out}"
          )
        end

        OsCtl::Lib::SystemCommandResult.new(ret, out)
      end
    end
  end
end
