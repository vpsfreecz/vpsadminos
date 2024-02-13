require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'
require 'osctld/container_control/utils/wall'

module OsCtld
  # Send message to container users
  class ContainerControl::Commands::Wall < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      include ContainerControl::Utils::Wall::Frontend

      # @param message [String]
      # @param banner [Boolean]
      def execute(message:, banner: true)
        unless ct.running?
          raise ContainerControl::Error, 'container not running'
        end

        ret = exec_runner(args: [make_message(message, banner:)])
        ret.ok? || ret
      end
    end

    class Runner < ContainerControl::Runner
      include ContainerControl::Utils::Wall::Runner

      def execute(message)
        st = ct_wall(message)

        if st.exitstatus == 0
          ok
        else
          error("failed to send message: exit status #{$?.exitstatus}")
        end
      end
    end
  end
end
