require 'osctld/container_control/transient_network'

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
      transient_network = ContainerControl::TransientNetwork.new(ct) if opts[:transient_network]
      network_socket = transient_network&.runner_socket

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
      prlimits = ct.prlimits.export
      switch_extra_namespaces = opts.fetch(:switch_extra_namespaces, true)
      cgroup_path = opts.fetch(
        :cgroup_path,
        switch_extra_namespaces ? ct.entry_cgroup_path : ct.attach_cgroup_path
      )
      cleanup_cgroup_path = !switch_extra_namespaces && cgroup_path == ct.attach_cgroup_path

      if switch_extra_namespaces
        # This path creates a boundary only for a new transient run. Running
        # attachment belongs to LXC's pidfd transition, never root setns of a
        # late numeric PID (or separate syslog/tracing namespace descriptors).
        raise ContainerControl::Error, 'container started before transient helper launch' if ct.init_pid

        syslogns_tag = ct.syslogns_tag(run_id: ct.run_conf&.run_id)
      end

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
        network_socket: network_socket&.fileno,
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
          stderr,
          network_socket
        ].compact
      ) do
        # Closed by SwitchUser.fork
        # cmd_w.close
        # ret_r.close

        $stdin.reopen(cmd_r)

        [cmd_r, ret_w, stdin, stdout, stderr, network_socket].compact.each do |io|
          io.close_on_exec = false
        end

        SwitchUser.apply_prlimits(Process.pid, prlimits)
        SwitchUser.switch_to(
          sysuser,
          ugid,
          homedir,
          cgroup_path,
          syslogns_tag:
        )
        Process.exec(::OsCtld.bin('osctld-ct-runner'))
      rescue StandardError => e
        write_runner_failure(ret_w, e)
        exit(false)
      end

      stdin.close if stdin
      stdout.close if stdout != $stdout
      stderr.close if stderr != $stderr

      # The child blocks on its command pipe until this exact identity is
      # pinned. Numeric PID reuse therefore cannot select another helper.
      runner_identity = ProcessIdentity.open(pid) if transient_network
      network_socket&.close

      cmd_w.write(runner_opts.to_json)
      cmd_w.close

      ret_w.close
      transient_network&.serve(runner_identity)

      begin
        ret = JSON.parse(ret_r.readline, symbolize_names: true)
        runner_result(ret)
      rescue EOFError
        ContainerControl::Result.new(
          false,
          message: 'helper exited without a response'
        )
      end
    ensure
      transient_network&.close
      runner_identity&.close
      # Release a helper still waiting for its command when pinning or command
      # transport fails, then reap it just as on the successful result path.
      [cmd_r, cmd_w, ret_r, ret_w].compact.each { |io| io.close unless io.closed? }
      if pid
        begin
          Process.wait(pid)
        ensure
          cleanup_runner_cgroup(cgroup_path) if cleanup_cgroup_path
        end
      end
    end

    def cleanup_runner_cgroup(cgroup_path)
      CGroup.rmpath_all(cgroup_path)
    rescue SystemCallError => e
      ct.log(:warn, "Unable to remove runner cgroup #{cgroup_path}: #{e.message}")
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
    # @option opts [Array<IO>] :keep_fds additional descriptors kept in the runner
    # @option opts [Boolean] :switch_to_system
    #
    # @return [ContainerControl::Result]
    def fork_runner(opts = {})
      r, w = IO.pipe

      stdin = opts[:stdin]
      stdout = opts.fetch(:stdout, $stdout)
      stderr = opts.fetch(:stderr, $stderr)
      keep_fds = Array(opts[:keep_fds])

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

      pid = SwitchUser.fork(keep_fds: ([w, stdin, stdout, stderr] + keep_fds).compact) do
        # Closed by SwitchUser.fork
        # r.close

        begin
          Process.setproctitle(
            "osctld: #{ctid} " \
            "runner:#{command_class.name.split('::').last.downcase}"
          )

          if opts.fetch(:switch_to_system, true)
            SwitchUser.switch_to_system(sysuser, ugid, ugid, homedir)
          end

          runner = command_class::Runner.new(**runner_opts)
        rescue StandardError => e
          write_runner_failure(w, e, stage: :setup)
          exit(false)
        end

        begin
          ret = runner.execute(*args, **kwargs)
        rescue StandardError => e
          write_runner_failure(w, e, stage: :execution)
          exit(false)
        end

        begin
          w.write("#{ret.to_json}\n")
        rescue StandardError => e
          write_runner_failure(w, e, stage: :response)
          exit(false)
        end
      end

      w.close

      begin
        ret = JSON.parse(r.readline, symbolize_names: true)
        Process.wait(pid)
        runner_result(ret)
      rescue EOFError
        Process.wait(pid)
        ContainerControl::Result.new(
          false,
          message: 'helper exited without a response'
        )
      end
    end

    def write_runner_failure(io, error, stage: :setup)
      io.write("#{ContainerControl::Result.failure_payload(error, stage:).to_json}\n")
    rescue SystemCallError, IOError
      nil
    end

    def runner_result(payload)
      ct.log(:warn, payload[:diagnostic]) if payload[:diagnostic]
      ContainerControl::Result.from_runner(payload)
    end
  end
end
