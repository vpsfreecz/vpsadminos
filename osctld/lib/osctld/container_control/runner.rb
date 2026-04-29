require 'lxc'

module OsCtld
  # Runner is run in a forked&execed process and under the container's user
  class ContainerControl::Runner
    # osctld uses ruby-lxc attach for in-process maintenance blocks, not for
    # launching untrusted commands. Keep only personality setup: cgroup moves
    # fail from the already-placed runner on cgroup v2, dropped capabilities
    # break netns maintenance, and LSM exec transitions are irrelevant without
    # execve().
    LXC_ATTACH_FLAGS = LXC::LXC_ATTACH_SET_PERSONALITY

    attr_reader :pool, :ctid, :lxc_home, :user_home, :log_file

    # @param opts [Hash] container options
    # @option opts [String] :pool
    # @option opts [String] :id
    # @option opts [String] :lxc_home
    # @option opts [String] :user_home
    # @option opts [String] :log_file
    # @option opts [IO, nil] :stdin
    # @option opts [IO] :stdout
    # @option opts [IO] :stderr
    def initialize(**opts)
      @pool = opts[:pool]
      @ctid = opts[:id]
      @lxc_home = opts[:lxc_home]
      @user_home = opts[:user_home]
      @log_file = opts[:log_file]
      @stdin = opts[:stdin]
      @stdout = opts[:stdout]
      @stderr = opts[:stderr]
    end

    # Implement this method
    # @param args [Array] command arguments
    # @param kwargs [Array] command arguments
    # @return [Hash]
    def execute(*args, **kwargs)
      raise NotImplementedError
    end

    protected

    attr_reader :stdin, :stdout, :stderr

    def ok(out = nil)
      { status: true, output: out }
    end

    def error(msg)
      { status: false, message: msg }
    end

    def lxc_ct
      @lxc_ct ||= LXC::Container.new(ctid, lxc_home)
    end

    def system_path
      SwitchUser::SYSTEM_PATH
    end

    def setup_exec_env
      ENV.delete_if { |k, _| k != 'TERM' }
      ENV['PATH'] = system_path.join(':')
      ENV['HOME'] = user_home
    end

    def setup_exec_run_env
      setup_exec_env
      ENV['PATH'] = ['/run/wrappers/bin', ENV.fetch('PATH', nil)].join(':')
    end

    def lxc_attach_wait(**opts, &)
      attach_opts = { wait: true, flags: LXC_ATTACH_FLAGS }.merge(opts)

      exitstatus(lxc_ct.attach(attach_opts, &))
    end

    def lxc_attach_command(cmd, stdout:, stderr:, stdin: nil)
      pid = Process.fork do
        if stdin
          $stdin.reopen(stdin)
        else
          $stdin.close
        end

        $stdout.reopen(stdout)
        $stderr.reopen(stderr)

        setup_exec_env

        Process.exec(
          'lxc-attach',
          '-P', lxc_home,
          '-n', ctid,
          '--elevated-privileges=CGROUP',
          '--clear-env',
          "--set-var=PATH=#{system_path.join(':')}",
          '--set-var=HOME=/root',
          '--set-var=USER=root',
          '--',
          *Array(cmd)
        )
      end

      _, status = Process.wait2(pid)
      exitstatus(status)
    end

    def wait_for_lxc_stopped(timeout: 10)
      deadline = Time.now + timeout

      sleep(0.1) while lxc_ct.running? && Time.now < deadline
    end

    def wait_for_lxc_attachable(timeout: 10)
      deadline = Time.now + timeout

      loop do
        init_pid = lxc_ct.init_pid
        return true if lxc_ct.running? && init_pid && init_pid > 0
        return false if Time.now >= deadline

        sleep(0.1)
      end
    end

    def exitstatus(status)
      return wait_status_exitstatus(status) if status.is_a?(Integer)
      return status.exitstatus if status.exited?
      return 128 + status.termsig if status.signaled?

      1
    end

    def wait_status_exitstatus(status)
      return 1 if status < 0

      term_sig = status & 0x7f

      if term_sig == 0
        (status >> 8) & 0xff
      elsif term_sig == 0x7f
        1
      else
        128 + term_sig
      end
    end
  end
end
