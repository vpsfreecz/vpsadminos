require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'

module OsCtld
  # Execute block within a running container
  #
  # The block's return value is not captured.
  class ContainerControl::Commands::RunBlock < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      # @param opts [Hash]
      # @option [Proc] :block
      # @return [OsCtl::Lib::SystemCommandResult]
      def execute(opts)
        unless ct.running?
          raise ContainerControl::Error, 'container not running'
        end

        pipe_runner(args: [opts])
      end
    end

    class Runner < ContainerControl::Runner
      # @param opts [Hash]
      # @option [Proc] :block
      # @return [Integer] exit status
      def execute(opts)
        pid = lxc_ct.attach do
          setup_exec_env
          ENV['HOME'] = '/root'
          ENV['USER'] = 'root'
          opts[:block].call
        end

        _, status = Process.wait2(pid)
        ok(status.exitstatus)
      end
    end
  end
end
