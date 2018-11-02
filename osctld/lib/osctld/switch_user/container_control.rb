require 'fileutils'
require 'libosctl'
require 'lxc'

module OsCtld
  class SwitchUser::ContainerControl
    include OsCtl::Lib::Utils::Log

    PATH = %w(/bin /usr/bin /sbin /usr/sbin /run/current-system/sw/bin)

    # @param cmd [Symbol] command to call
    # @param cmd_opts [Hash] command options
    # @param ct_opts [Hash] container options
    # @option ct_opts [String] :lxc_home
    # @option ct_opts [String] :user_home
    # @option ct_opts [String] :log_file
    def self.run(cmd, cmd_opts, ct_opts)
      ur = new(ct_opts)
      ur.execute(cmd, cmd_opts)
    end

    def initialize(opts)
      @lxc_home = opts[:lxc_home]
      @user_home = opts[:user_home]
      @log_file = opts[:log_file]
    end

    def execute(cmd, opts)
      method(cmd).call(opts)
    end

    protected
    # Attempt a clean shutdown, fallback to kill
    # @param opts [Hash]
    # @option opts [String] :id container id
    # @option opts [Integer] :timeout how long to wait for clean shutdown
    def ct_stop(opts)
      ct = lxc_ct(opts[:id])

      if ct_shutdown(opts, ct)[:status]
        ok

      else
        ct_kill(opts, ct)
      end
    end

    # Kill container immediately
    # @param opts [Hash]
    # @option opts [String] :id container id
    # @param ct [SwitchUser::ContainerControl, nil]
    def ct_kill(opts, ct = nil)
      ct ||= lxc_ct(opts[:id])
      ct.stop
      ok

    rescue LXC::Error
      error('unable to kill container')
    end

    # Shutdown container cleanly or fail
    # @param opts [Hash]
    # @option opts [String] :id container id
    # @option opts [Integer] :timeout how long to wait for clean shutdown
    # @param ct [SwitchUser::ContainerControl, nil]
    def ct_shutdown(opts, ct = nil)
      ct ||= lxc_ct(opts[:id])
      ct.shutdown(opts[:timeout])
      ok

    rescue LXC::Error
      error('unable to shutdown container')
    end

    # Request container reboot
    # @param opts [Hash]
    # @option opts [String] :id container id
    def ct_reboot(opts)
      ct = lxc_ct(opts[:id])
      ct.reboot
    end

    def ct_status(opts)
      ret = {}

      opts[:ids].each do |id|
        ct = lxc_ct(id)

        ret[id] = {
          state: ct.state,
          init_pid: ct.init_pid,
        }
      end

      ok(ret)
    end

    # Execute command in a running container
    # @param opts [Hash]
    # @option opts [String] :id container id
    # @option opts [String] :cmd command to execute
    # @option opts [IO] :stdin
    # @option opts [IO] :stdout
    # @option opts [IO] :stderr
    def ct_exec_running(opts)
      pid = lxc_ct(opts[:id]).attach(
        stdin: opts[:stdin],
        stdout: opts[:stdout],
        stderr: opts[:stderr]
      ) do
        setup_exec_env
        LXC.run_command(opts[:cmd])
      end

      _, status = Process.wait2(pid)
      ok(exitstatus: status.exitstatus)
    end

    # Execute command in a stopped container
    # @param opts [Hash]
    # @option opts [String] :id container id
    # @option opts [String] :cmd command to execute
    # @option opts [IO] :stdin
    # @option opts [IO] :stdout
    # @option opts [IO] :stderr
    def ct_exec_run(opts)
      pid = Process.fork do
        STDIN.reopen(opts[:stdin])
        STDOUT.reopen(opts[:stdout])
        STDERR.reopen(opts[:stderr])

        setup_exec_env

        cmd = [
          'lxc-execute',
          '-P', @lxc_home,
          '-n', opts[:id],
          '-o', @log_file,
          '-s', "lxc.environment=PATH=#{PATH.join(':')}",
          '--',
          opts[:cmd],
        ]

        # opts[:cmd] can contain an arbitrary command with multiple arguments
        # and quotes, so the mapping to process arguments is not clear. We use
        # the shell to handle this.
        Process.exec("exec #{cmd.join(' ')}")
      end

      _, status = Process.wait2(pid)
      ok(exitstatus: status.exitstatus)
    end

    # Execute command in a stopped container with the network configured
    # @param opts [Hash]
    # @option opts [String] :id container id
    # @option opts [String] :init_script path to the script used to control
    #                                    the container
    # @option opts [NetConfig] :net_config
    # @option opts [String] :cmd command to execute
    # @option opts [IO] :stdin
    # @option opts [IO] :stdout
    # @option opts [IO] :stderr
    def ct_exec_network(opts)
      with_configured_network(
        id: opts[:id],
        init_script: opts[:init_script],
        net_config: opts[:net_config],
      ) { ct_exec_running(opts) }
    end

    # Execute script in a running container
    # @param opts [Hash]
    # @option opts [String] :id container id
    # @option opts [String] :script path to the script relative to the rootfs
    # @option opts [IO] :stdin
    # @option opts [IO] :stdout
    # @option opts [IO] :stderr
    def ct_runscript_running(opts)
      pid = lxc_ct(opts[:id]).attach(
        stdin: opts[:stdin],
        stdout: opts[:stdout],
        stderr: opts[:stderr]
      ) do
        setup_exec_env
        LXC.run_command(opts[:script])
      end

      _, status = Process.wait2(pid)
      ok(exitstatus: status.exitstatus)
    end

    # Execute command in a stopped container
    # @param opts [Hash]
    # @option opts [String] :id container id
    # @option opts [String] :script path to the script relative to the rootfs
    # @option opts [IO] :stdin
    # @option opts [IO] :stdout
    # @option opts [IO] :stderr
    # @option opts [Array<IO>] :close_fds
    # @option opts [Boolean] :wait
    def ct_runscript_run(opts)
      pid = Process.fork do
        STDIN.reopen(opts[:stdin])
        STDOUT.reopen(opts[:stdout])
        STDERR.reopen(opts[:stderr])

        opts[:close_fds] && opts[:close_fds].each { |fd| fd.close }

        setup_exec_env

        cmd = [
          'lxc-execute',
          '-P', @lxc_home,
          '-n', opts[:id],
          '-o', @log_file,
          '-s', "lxc.environment=PATH=#{PATH.join(':')}",
          '--',
          opts[:script],
        ]

        # opts[:cmd] can contain an arbitrary command with multiple arguments
        # and quotes, so the mapping to process arguments is not clear. We use
        # the shell to handle this.
        Process.exec("exec #{cmd.join(' ')}")
      end

      if opts[:wait] === false
        pid
      else
        _, status = Process.wait2(pid)
        ok(exitstatus: status.exitstatus)
      end
    end

    # Execute script in a stopped container
    # @param opts [Hash]
    # @option opts [String] :id container id
    # @option opts [String] :init_script path to the script used to control
    #                                    the container
    # @option opts [NetConfig] :net_config
    # @option opts [String] :script path to the script relative to the rootfs
    # @option opts [IO] :stdin
    # @option opts [IO] :stdout
    # @option opts [IO] :stderr
    def ct_runscript_network(opts)
      with_configured_network(
        id: opts[:id],
        init_script: opts[:init_script],
        net_config: opts[:net_config],
      ) { ct_runscript_running(opts) }
    end

    def veth_name(opts)
      ct = lxc_ct(opts[:id])
      ok(ct.running_config_item("lxc.net.#{opts[:index]}.veth.pair"))
    end

    # Relocate mount from the host-shared directory into the correct place
    # @param opts [Hash]
    # @option opts [String] :id container id
    # @option opts [String] :shared_dir path to the host-shared directory
    # @option opts [String] :src directory inside `:shared_dir` to relocate
    # @option opts [String] :dst target mountpoint
    def mount(opts)
      ct = lxc_ct(opts[:id])

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
            Mount::Sys.move_mount(src, opts[:dst])
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

    # Unmount directory from a container
    # @param opts [Hash]
    # @option opts [String] :id container id
    # @option opts [String] :mountpoint
    def unmount(opts)
      ct = lxc_ct(opts[:id])

      pid = ct.attach do
        next unless Dir.exist?(opts[:mountpoint])

        begin
          Mount::Sys.unmount(opts[:mountpoint])

        rescue Errno::EINVAL
          # Not mounted, pass
        end
      end

      Process.wait(pid)

      if $?.exitstatus == 0
        ok

      else
        log(:warn, ct, "Unmounter exited with #{$?.exitstatus}")
        error('unmount failed')
      end
    end

    def lxc_ct(id)
      LXC::Container.new(id, @lxc_home)
    end

    def setup_exec_env
      ENV.delete_if { |k, _| k != 'TERM' }
      ENV['PATH'] = PATH.join(':')
      ENV['HOME'] = @user_home
    end

    # Start container with lxc-init, configure network and yield
    #
    # opts[:init_script] has to contain path to a script that will be executed
    # by lxc-init. The purpose of this script is to keep the container running
    # while the network is being configured and the user command is executed.
    # The script has to write `ready\n` to standard output, then block on read
    # from standard input and exit.
    #
    # @param opts [Hash]
    # @option opts [String] :id container id
    # @option opts [String] :init_script path to the script used to control
    #                                    the container
    # @option opts [NetConfig] :net_config
    def with_configured_network(opts)
      # Pipes for communicating with opts[:init_script]
      in_r, in_w = IO.pipe
      out_r, out_w = IO.pipe

      # Start the container with lxc-init
      init_pid = ct_runscript_run(
        id: opts[:id],
        script: opts[:init_script],
        stdin: in_r,
        stdout: out_w,
        stderr: out_w,
        close_fds: [in_w, out_r],
        wait: false,
      )

      in_r.close
      out_w.close

      # Wait for the container to be started
      if out_r.readline.strip == 'ready'
        # Configure network
        pid = lxc_ct(opts[:id]).attach do
          setup_exec_env
          opts[:net_config].setup
        end

        Process.wait2(pid)

        # Execute user command
        yield
      end

      # Closing in_w will bring down opts[:init_script] and stop the container
      in_w.close
      out_r.close

      _, status = Process.wait2(init_pid)
      ok(exitstatus: status.exitstatus)
    end

    def ok(out = nil)
      {status: true, output: out}
    end

    def error(msg)
      {status: false, message: msg}
    end
  end
end
