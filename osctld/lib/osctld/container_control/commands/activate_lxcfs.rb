require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'

module OsCtld
  # Initialize LXCFS accounting of /proc/stat and /proc/loadavg
  class ContainerControl::Commands::ActivateLxcfs < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      # @return [true]
      def execute
        unless ct.running?
          raise ContainerControl::Error, 'container not running'
        end

        ret = exec_runner
        ret.ok? || ret
      end
    end

    class Runner < ContainerControl::Runner
      def execute
        pid = lxc_ct.attach do
          File.open('/proc/stat', 'r') { |f| f.readline }
          File.open('/proc/loadavg', 'r') { |f| f.readline }
        end

        Process.wait(pid)

        if $?.exitstatus == 0
          ok
        else
          error("failed to activate lxcfs: exit status #{$?.exitstatus}")
        end
      end
    end
  end
end
