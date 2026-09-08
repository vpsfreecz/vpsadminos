require 'libosctl'
require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'

module OsCtld
  # Unmount directory from a container
  class ContainerControl::Commands::Unmount < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      # @param mountpoint [String]
      # @return [true]
      def execute(mountpoint)
        ret = exec_runner(args: [mountpoint], switch_extra_namespaces: false)
        ret.ok? || ret
      end
    end

    class Runner < ContainerControl::Runner
      include OsCtl::Lib::Utils::Log

      # @param mountpoint [String]
      def execute(mountpoint)
        ct = lxc_ct

        exit_status = lxc_attach_wait do
          next unless Dir.exist?(mountpoint)

          begin
            sys = OsCtl::Lib::Sys.new
            sys.unmount(mountpoint)
          rescue Errno::EINVAL
            # Not mounted, pass
          end
        end

        if exit_status == 0
          ok
        else
          log(:warn, ct, "Unmounter exited with #{exit_status}")
          error('unmount failed')
        end
      end
    end
  end
end
