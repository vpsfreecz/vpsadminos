require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'

module OsCtld
  # Request container reboot
  class ContainerControl::Commands::Reboot < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      # @return [true]
      def execute
        ret = pipe_runner
        ret.ok? || ret
      end
    end

    class Runner < ContainerControl::Runner
      def execute
        lxc_ct.reboot
        ok
      end
    end
  end
end
