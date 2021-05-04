require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'

module OsCtld
  class ContainerControl::Commands::Freeze < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      # @return [true]
      def execute
        ret = exec_runner
        ret.ok? || ret
      end
    end

    class Runner < ContainerControl::Runner
      def execute
        lxc_ct.freeze
        ok
      end
    end
  end
end
