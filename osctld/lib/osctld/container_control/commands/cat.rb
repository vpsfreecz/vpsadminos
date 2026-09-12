require 'json'
require 'osctld/container_control/command'
require 'osctld/container_control/frontend'
require 'osctld/container_control/runner'

module OsCtld
  # Read files with host Ruby, without executing a binary from the container.
  class ContainerControl::Commands::Cat < ContainerControl::Command
    class Frontend < ContainerControl::Frontend
      def execute(files:, stdout:)
        raise ContainerControl::Error, 'container not running' unless ct.running?

        ret = exec_runner(
          args: [files],
          stdout:,
          switch_extra_namespaces: false
        )
        ret.ok? ? ret.data : ret
      end
    end

    class Runner < ContainerControl::Runner
      def execute(files)
        lxc_ct.set_config_item('lxc.log.file', log_file)
        lxc_ct.set_config_item('lxc.log.level', 'TRACE')
        result_r, result_w = IO.pipe
        # Use LXC's authenticated namespace transition, including userns. A
        # mount-only host-userns reader can invalidate shared proc dentries
        # and detach container submounts on older running kernels.
        pid = lxc_ct.attach(
          wait: false,
          flags: LXC_ATTACH_FLAGS,
          initial_cwd: '/'
        ) do
          result_r.close
          errors = {}

          files.each do |file|
            File.open(file) { |io| IO.copy_stream(io, stdout) }
          rescue SystemCallError => e
            errors[file] = e.message
          end

          result_w.write(errors.to_json)
          result_w.close
        end

        if pid <= 0
          pid = nil
          return error('unable to attach file reader')
        end

        result_w.close
        # Drain before wait: per-file errors can exceed the pipe capacity.
        result = result_r.read
        _, status = Process.wait2(pid)
        pid = nil
        return error("file reader exited with #{exitstatus(status)}") unless status.success?

        ok(JSON.parse(result))
      rescue JSON::ParserError
        error('file reader returned an invalid result')
      ensure
        result_r&.close unless result_r&.closed?
        result_w&.close unless result_w&.closed?
        Process.wait(pid) if pid
      end
    end
  end
end
