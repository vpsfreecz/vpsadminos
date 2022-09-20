require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'
require 'libosctl'
require 'socket'

module OsCtld
  # Read container hostname from its UTS namespace
  class ContainerControl::Commands::GetHostname < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      # @return [String]
      def execute
        init_pid = ct.init_pid

        if init_pid.nil?
          return ContainerControl::Result.new(
            false,
            message: 'container not running or init PID not set',
          )
        end

        ret = fork_runner(args: [init_pid], switch_to_system: false)
        ret.ok? ? ret.data : ret
      end
    end

    class Runner < ContainerControl::Runner
      def execute(init_pid)
        sys = OsCtl::Lib::Sys.new
        sys.setns_path(
          File.join('/proc', init_pid.to_s, 'ns/uts'),
          OsCtl::Lib::Sys::CLONE_NEWUTS,
        )
        ok(Socket.gethostname)
      end
    end
  end
end
