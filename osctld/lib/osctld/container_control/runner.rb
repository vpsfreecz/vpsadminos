require 'lxc'

module OsCtld
  # Runner is run in a forked&execed process and under the container's user
  class ContainerControl::Runner
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
  end
end
