require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'

module OsCtld
  # Prepare runit within a container for graceful shutdown
  class ContainerControl::Commands::StopRunit < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      include ContainerControl::Utils::Wall::Frontend

      # @param opts [Hash] options
      # @option opts [String, nil] :message
      # @return [true]
      def execute(**opts)
        unless ct.running?
          raise ContainerControl::Error, 'container not running'
        end

        msg = if opts[:message]
                make_message(opts[:message])
              end

        ret = exec_runner(args: [{ message: msg }])
        ret.ok? || ret
      end
    end

    class Runner < ContainerControl::Runner
      include ContainerControl::Utils::Wall::Runner

      # @param opts [Hash] options
      # @option opts [String, nil] :message
      # @return [Integer] exit status
      def execute(opts)
        if opts[:message]
          begin
            ct_wall(opts[:message])
          rescue LXC::Error
            # ignore
          end
        end

        pid = lxc_ct.attach do
          setup_exec_env
          ENV['HOME'] = '/root'
          ENV['USER'] = 'root'

          next unless Dir.exist?('/etc/runit')

          # Only the existence of the reboot file can trigger reboot
          if File.exist?('/etc/runit/reboot')
            File.new('/etc/runit/reboot', 'w', 0).close
            File.chmod(0, '/etc/runit/reboot')
          end

          File.new('/etc/runit/stopit', 'w', 0o100).close
          File.chmod(0o100, '/etc/runit/stopit')
        end

        Process.wait(pid)

        if $?.exitstatus == 0
          ok
        else
          error("runit-stop failed with exit status #{$?.exitstatus}")
        end
      end
    end
  end
end
