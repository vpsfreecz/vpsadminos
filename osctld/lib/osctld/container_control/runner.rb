require 'lxc'

module OsCtld
  # Runner is run in a forked process and under the container's user
  class ContainerControl::Runner
    attr_reader :ctid, :lxc_home, :user_home, :log_file

    # @param opts [Hash] container options
    # @option opts [String] :lxc_home
    # @option opts [String] :user_home
    # @option opts [String] :log_file
    def initialize(opts)
      @ctid = opts[:id]
      @lxc_home = opts[:lxc_home]
      @user_home = opts[:user_home]
      @log_file = opts[:log_file]
    end

    # Implement this method
    # @param args [Array] command arguments
    # @return [Hash]
    def execute(*args)
      raise NotImplementedError
    end

    protected
    def ok(out = nil)
      {status: true, output: out}
    end

    def error(msg)
      {status: false, message: msg}
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
  end
end
