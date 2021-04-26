require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'

module OsCtld
  # Prepare runit within a container for graceful shutdown
  class ContainerControl::Commands::StopRunit < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      # @return [true]
      def execute
        unless ct.running?
          raise ContainerControl::Error, 'container not running'
        end

        ret = pipe_runner
        ret.ok? || ret
      end
    end

    class Runner < ContainerControl::Runner
      # @return [Integer] exit status
      def execute
        pid = lxc_ct.attach do
          setup_exec_env
          ENV['HOME'] = '/root'
          ENV['USER'] = 'root'

          next unless Dir.exist?('/etc/runit')

          # Only the existence of the reboot file can trigger reboot
          if File.exist?('/etc/runit/reboot')
            File.open('/etc/runit/reboot', 'w', 0) {}
            File.chmod(0, '/etc/runit/reboot')
          end

          File.open('/etc/runit/stopit', 'w', 0100) {}
          File.chmod(0100, '/etc/runit/stopit')
        end

        Process.wait(pid)

        if $?.exitstatus == 0
          ok
        else
          log(:warn, ct, "runit-stop exited with #{$?.exitstatus}")
          error('runit-stop failed')
        end
      end
    end
  end
end
