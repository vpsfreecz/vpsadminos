module OsCtld
  # Frontend is run from osctld in daemon mode, when it is running as root
  class ContainerControl::Frontend
    # @return [Class]
    attr_reader :command_class

    # @return [Container]
    attr_reader :ct

    # @param command_class [Class]
    # @param ct [Container]
    def initialize(command_class, ct)
      @command_class = command_class
      @ct = ct
    end

    # Implement this method
    # @param args [Array] command arguments
    # @param kwargs [Array] command arguments
    def execute(*args, **kwargs)
      raise NotImplementedError
    end

    protected

    # Fork&exec to the container user and invoke the runner.
    #
    # {#exec_runner} forks from osctld and then execs into osctld-ct-runner.
    # The runner then switches to the container's user and enters its cgroups.
    # This runner is safe to use when you need to attach to the container, e.g.
    # with {LXC::Container#attach}.
    #
    # It is however more costly than {#fork_runner} as it makes the Ruby runtime
    # to start all over again. Use {#fork_runner} when you don't need to attach
    # to the container.
    #
    # @param opts [Hash]
    # @option opts [Array] :args command arguments
    # @option opts [Hash] :kwargs command arguments
    # @option opts [Boolean, nil] :reset_subtree_control
    # @option opts [IO, nil] :stdin
    # @option opts [IO, nil] :stdout
    # @option opts [IO, nil] :stderr
    # @option opts [String, nil] :run_id
    # @option opts [String, nil] :lxc_config
    # @option opts [String, nil] :cgroup_path
    # @option opts [String, nil] :reset_subtree_control_path
    # @option opts [Proc, nil] :on_spawn called before the runner is released
    # @option opts [Proc, nil] :on_reap called after the runner is reaped
    # @option opts [Boolean] :lifecycle_owned caller already has an exact
    #                                            lifecycle effect
    #
    # @return [ContainerControl::Result]
    def exec_runner(opts = {})
      # Used to send command to the runner
      cmd_r, cmd_w = IO.pipe

      # Used to read return value
      ret_r, ret_w = IO.pipe

      # Keep the runner blocked until its exact lifecycle lease is durable
      continue_r, continue_w = IO.pipe

      # File descriptors to capture output/feed input
      stdin = opts[:stdin]
      stdout = opts.fetch(:stdout, $stdout)
      stderr = opts.fetch(:stderr, $stderr)

      # User configuration
      sysuser = ct.user.sysusername
      ugid = ct.user.ugid
      homedir = ct.user.homedir
      cgroup_path = opts.fetch(:cgroup_path, ct.entry_cgroup_path)
      prlimits = ct.prlimits.export
      syslogns_pid = ct.init_pid
      syslogns_tag = syslogns_pid.nil? && ct.syslogns_tag
      on_spawn = opts[:on_spawn]
      on_reap = opts[:on_reap]
      unless opts[:lifecycle_owned] || on_spawn
        run_id = ct.lifecycle.active_run_id
        unless run_id
          raise ContainerControl::Error, 'managed lifecycle run not found'
        end

        on_spawn = proc do |pid|
          process_id = Daemon.get.with_lifecycle_admission do
            ct.lifecycle.register_attachment(run_id, pid:)
          end
          unless process_id
            raise ContainerControl::Error,
                  'container stopped before command attachment'
          end

          process_id
        end
        on_reap = proc do |_pid, process_id|
          finish_lifecycle_attachment(run_id, process_id) if process_id
        end
      end

      # Runner configuration
      runner_opts = {
        name: command_class.name,

        pool: ct.pool.name,
        id: ct.id,
        lxc_home: ct.lxc_home,
        user_home: ct.user.homedir,
        log_file: ct.log_path,
        run_id: opts[:run_id],
        lxc_config: opts[:lxc_config],

        args: opts.fetch(:args, []),
        kwargs: opts.fetch(:kwargs, {}),

        return: ret_w.fileno,
        stdin: stdin && stdin.fileno,
        stdout: stdout.fileno,
        stderr: stderr.fileno
      }

      waited = false
      spawn_value = nil
      pid = SwitchUser.fork(
        keep_fds: [
          cmd_r,
          ret_w,
          continue_r,
          stdin,
          stdout,
          stderr
        ].compact
      ) do
        # Closed by SwitchUser.fork
        # cmd_w.close
        # ret_r.close

        continue = continue_r.readline.strip
        continue_r.close
        exit(false) unless continue == 'ready'

        $stdin.reopen(cmd_r)

        [cmd_r, ret_w, stdin, stdout, stderr].compact.each do |io|
          io.close_on_exec = false
        end

        SwitchUser.apply_prlimits(Process.pid, prlimits)
        SwitchUser.switch_to(
          sysuser,
          ugid,
          homedir,
          cgroup_path,
          syslogns_pid:,
          syslogns_tag:
        )
        runner = ::OsCtld.bin('osctld-ct-runner')
        Process.exec(runner)
        exit
      end

      begin
        cmd_r.close
        continue_r.close
        stdin.close if stdin
        stdout.close if stdout != $stdout
        stderr.close if stderr != $stderr

        # Lifecycle admission must be durable before this command can recreate
        # or enter any container cgroup. Policy changes and recovery use the
        # same process lease as their topology fence.
        spawn_value = on_spawn&.call(pid)
        CGroup.mkpath_all(cgroup_path.split('/'), chown: ugid)

        # On cgroup v2, reset subtree control only in the exact generation's
        # user-owned subtree which lxc-execute will manage.
        if opts.fetch(:reset_subtree_control, false) && CGroup.v2?
          reset_path =
            opts.fetch(
              :reset_subtree_control_path,
              ct.cgroup_path
            )
          CGroup.mkpath_all(reset_path.split('/'), chown: ugid)
          CGroup.reset_subtree_control(
            CGroup.abs_cgroup_path(nil, reset_path)
          )
        end
        continue_w.puts('ready')
        continue_w.close
        cmd_w.write(runner_opts.to_json)
        cmd_w.close

        ret_w.close

        ret = JSON.parse(ret_r.readline, symbolize_names: true)
        Process.wait(pid)
        waited = true
        ContainerControl::Result.from_runner(ret)
      rescue EOFError
        _, status = Process.wait2(pid)
        waited = true
        ContainerControl::Result.new(
          false,
          message: "user runner failed (#{format_process_status(status)})",
          user_runner: true
        )
      ensure
        cmd_w.close unless cmd_w.closed?
        cmd_r.close unless cmd_r.closed?
        ret_r.close unless ret_r.closed?
        ret_w.close unless ret_w.closed?
        continue_r.close unless continue_r.closed?
        continue_w.close unless continue_w.closed?
        unless waited
          begin
            Process.wait(pid)
          rescue Errno::ECHILD
            nil
          end
        end
        on_reap&.call(pid, spawn_value)
      end
    end

    def finish_lifecycle_attachment(run_id, process_id)
      effect_id = ct.lifecycle.finish_process(run_id, process_id)
      return unless effect_id

      run_conf = [ct.run_conf, ct.get_past_run_conf].compact.detect do |conf|
        conf.run_id == run_id
      end
      return unless run_conf

      require 'osctld/container/lifecycle_finalizer'
      Container::LifecycleFinalizer.spawn(ct, run_conf, effect_id)
    end

    def format_process_status(status)
      if status.exited?
        "exit status #{status.exitstatus}"
      elsif status.signaled?
        "signal #{Signal.signame(status.termsig)}"
      else
        status.to_s
      end
    end

    # Fork to the container user and invoke the runner.
    #
    # {#fork_runner} can be used only when we do not need to enter the container
    # itself. It does not attach to its cgroups, because a forked osctld can
    # have a large memory footprint, which we do not want to charge to
    # the container. It can be used only to interact with LXC from the outside.
    #
    # @param opts [Hash]
    # @option opts [Array] :args command arguments
    # @option opts [Hash] :kwargs command arguments
    # @option opts [IO, nil] :stdin
    # @option opts [IO, nil] :stdout
    # @option opts [IO, nil] :stderr
    # @option opts [Boolean] :switch_to_system
    #
    # @return [ContainerControl::Result]
    def fork_runner(opts = {})
      r, w = IO.pipe

      stdin = opts[:stdin]
      stdout = opts.fetch(:stdout, $stdout)
      stderr = opts.fetch(:stderr, $stderr)

      runner_opts = {
        id: ct.id,
        lxc_home: ct.lxc_home,
        user_home: ct.user.homedir,
        log_file: ct.log_path,
        stdin:,
        stdout:,
        stderr:
      }

      ctid = ct.ident
      args = opts.fetch(:args, [])
      kwargs = opts.fetch(:kwargs, {})
      sysuser = ct.user.sysusername
      ugid = ct.user.ugid
      homedir = ct.user.homedir

      pid = SwitchUser.fork(keep_fds: [w, stdin, stdout, stderr].compact) do
        # Closed by SwitchUser.fork
        # r.close

        Process.setproctitle(
          "osctld: #{ctid} " \
          "runner:#{command_class.name.split('::').last.downcase}"
        )

        if opts.fetch(:switch_to_system, true)
          SwitchUser.switch_to_system(sysuser, ugid, ugid, homedir)
        end

        runner = command_class::Runner.new(**runner_opts)
        ret = runner.execute(*args, **kwargs)
        w.write("#{ret.to_json}\n")

        exit
      end

      w.close

      begin
        ret = JSON.parse(r.readline, symbolize_names: true)
        Process.wait(pid)
        ContainerControl::Result.from_runner(ret)
      rescue EOFError
        Process.wait(pid)
        ContainerControl::Result.new(
          false,
          message: 'user runner failed',
          user_runner: true
        )
      end
    end
  end
end
