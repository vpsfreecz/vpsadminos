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
    #
    # @return [ContainerControl::Result]
    def exec_runner(opts = {})
      # Used to send command to the runner
      cmd_r, cmd_w = IO.pipe

      # Used to read return value
      ret_r, ret_w = IO.pipe

      # File descriptors to capture output/feed input
      stdin = opts[:stdin]
      stdout = opts.fetch(:stdout, $stdout)
      stderr = opts.fetch(:stderr, $stderr)

      # User configuration
      sysuser = ct.user.sysusername
      ugid = ct.user.ugid
      homedir = ct.user.homedir
      cgroup_path = ct.entry_cgroup_path
      prlimits = ct.prlimits.export
      syslogns_pid = ct.init_pid
      syslogns_tag = syslogns_pid.nil? && ct.syslogns_tag

      # Runner configuration
      runner_opts = {
        name: command_class.name,

        pool: ct.pool.name,
        id: ct.id,
        lxc_home: ct.lxc_home,
        user_home: ct.user.homedir,
        log_file: ct.log_path,

        args: opts.fetch(:args, []),
        kwargs: opts.fetch(:kwargs, {}),

        return: ret_w.fileno,
        stdin: stdin && stdin.fileno,
        stdout: stdout.fileno,
        stderr: stderr.fileno
      }

      CGroup.mkpath_all(cgroup_path.split('/'), chown: ugid)

      # On cgroup v2, we must reset subtree control for lxc-execute to work.
      # The subtree control is configured by osctld when creating the entry_cgroup_path,
      # which is a bit unfortunate in this case.
      if opts.fetch(:reset_subtree_control, false) && CGroup.v2?
        CGroup.reset_subtree_control(ct.abs_cgroup_path(nil))
      end

      pid = SwitchUser.fork(
        keep_fds: [
          cmd_r,
          ret_w,
          stdin,
          stdout,
          stderr
        ].compact
      ) do
        # Closed by SwitchUser.fork
        # cmd_w.close
        # ret_r.close

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
        Process.exec(::OsCtld.bin('osctld-ct-runner'))
        exit
      end

      stdin.close if stdin
      stdout.close if stdout != $stdout
      stderr.close if stderr != $stderr

      cmd_w.write(runner_opts.to_json)
      cmd_w.close

      ret_w.close

      begin
        ret = JSON.parse(ret_r.readline, symbolize_names: true)
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
