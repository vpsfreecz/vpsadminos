require 'lxc'
require 'libosctl/sys'

module OsCtld
  # Runner is run in a forked&execed process and under the container's user
  class ContainerControl::Runner
    attr_reader :pool, :ctid, :lxc_home, :user_home, :log_file, :run_id,
                :lxc_config

    # @param opts [Hash] container options
    # @option opts [String] :pool
    # @option opts [String] :id
    # @option opts [String] :lxc_home
    # @option opts [String] :user_home
    # @option opts [String] :log_file
    # @option opts [String, nil] :run_id
    # @option opts [String, nil] :lxc_config
    # @option opts [IO, nil] :stdin
    # @option opts [IO] :stdout
    # @option opts [IO] :stderr
    def initialize(**opts)
      @pool = opts[:pool]
      @ctid = opts[:id]
      @lxc_home = opts[:lxc_home]
      @user_home = opts[:user_home]
      @log_file = opts[:log_file]
      @run_id = opts[:run_id]
      @lxc_config = opts[:lxc_config]
      @stdin = opts[:stdin]
      @stdout = opts[:stdout]
      @stderr = opts[:stderr]
      @runner_pid = Process.pid
    end

    # Implement this method
    # @param args [Array] command arguments
    # @param kwargs [Array] command arguments
    # @return [Hash]
    def execute(*args, **kwargs)
      raise NotImplementedError
    end

    protected

    attr_reader :stdin, :stdout, :stderr, :runner_pid

    def ok(out = nil)
      { status: true, output: out }
    end

    def error(msg)
      { status: false, message: msg }
    end

    def lxc_ct
      @lxc_ct ||= begin
        container = LXC::Container.new(ctid, lxc_home)

        if lxc_config
          container.clear_config
          container.load_config(lxc_config)
        end

        container
      end
    end

    def system_path
      SwitchUser::SYSTEM_PATH
    end

    def setup_exec_env
      protect_runner_child
      ENV.delete_if { |k, _| k != 'TERM' }
      ENV['PATH'] = system_path.join(':')
      ENV['HOME'] = user_home
    end

    def setup_exec_run_env
      setup_exec_env
      ENV['PATH'] = ['/run/wrappers/bin', ENV.fetch('PATH', nil)].join(':')
    end

    # The lifecycle lease tracks the runner. Its attached/forked child must
    # not outlive it and continue changing container topology after the lease
    # owner disappears.
    def protect_runner_child
      return if Process.pid == runner_pid

      OsCtl::Lib::Sys.new.set_parent_death_signal('KILL')
      exit! unless Process.ppid == runner_pid
    end
  end
end
