require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'

module OsCtld
  # Relocate mount from the host-shared directory into the container
  class ContainerControl::Commands::Mount < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      # @param opts [Hash]
      # @option opts [String] :shared_dir path to the host-shared directory
      # @option opts [String] :src directory inside `:shared_dir` to relocate
      # @option opts [String] :dst target mountpoint
      # @return [true]
      def execute(opts)
        ret = pipe_runner(args: [opts])
        ret.ok? || ret
      end
    end

    class Runner < ContainerControl::Runner
      # @param opts [Hash]
      # @option opts [String] :shared_dir path to the host-shared directory
      # @option opts [String] :src directory inside `:shared_dir` to relocate
      # @option opts [String] :dst target mountpoint
      def execute(opts)
        ct = lxc_ct
        r, w = IO.pipe

        pid = ct.attach(stdout: w) do
          r.close

          begin
            src = File.join(opts[:shared_dir], opts[:src])

            if !Dir.exist?(opts[:shared_dir])
              puts "error:Shared dir not found at: #{opts[:shared_dir]}"

            elsif !Dir.exist?(src)
              puts "error:Source directory not found at: #{src}"

            else
              FileUtils.mkpath(opts[:dst])

              # Since Linux 5.1, move_mount started to fail with
              # Errno::EINVAL, Invalid argument. Bind mount seems to achieve
              # the same result.
              Mount::Sys.bind_mount(src, opts[:dst])
              puts 'ok:done'
            end

          rescue => e
            puts "error:Exception (#{e.class}): #{e.message}"

          ensure
            STDOUT.flush
          end
        end

        w.close

        line = r.readline
        Process.wait(pid)
        r.close
        log(:warn, ct, "Mounter exited with #{$?.exitstatus}") if $?.exitstatus != 0

        i = line.index(':')
        return error("invalid return value: #{line.inspect}") unless i

        status = line[0..i-1]
        msg = line[i+1..-1]

        if status == 'ok'
          ok
        else
          error(msg)
        end
      end
    end
  end
end
