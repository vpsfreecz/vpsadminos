require 'libosctl'

module OsCtld
  class Container::Hooks::Base
    class << self
      attr_reader :hook_name

      # Register hook unde a name
      # @param name [Symbol]
      def hook(name)
        @hook_name = name
        Container::Hook.register(name, self)
      end

      # Mark the hook as blocking or async, defaults to async
      # @param v [Boolean] `true` for blocking, `false` for async
      def blocking(v)
        @blocking = v
      end

      def blocking?
        @blocking || false
      end

      # Run hook
      def run(ct, opts)
        return unless exist?(ct)
        hook = new(ct, opts)
        hook.exec
      end

      def exist?(ct)
        File.executable?(hook_path(ct))
      end

      def hook_path(ct)
        File.join(ct.user_hook_script_dir, hook_name.to_s.gsub(/_/, '-'))
      end
    end

    include OsCtl::Lib::Utils::Log

    # @return [Container]
    attr_reader :ct

    def initialize(ct, opts)
      @ct = ct
      @opts = opts
    end

    # Execute the user script hook.
    #
    # For blocking hooks, this method waits for the script hook to exit. If it
    # exits with non-zero exit status, exception {HookFailed} is raised. Async
    # hooks return immediately and their exit status has no meaning.
    def exec
      log(
        :info,
        ct,
        "Executing hook #{self.class.hook_name} at #{hook_path}"
      )

      env = environment

      pid = Process.fork do
        ENV.delete_if { |k,_| k != 'PATH' }
        env.each { |k, v| ENV[k] = v }

        Process.exec(*executable)
      end

      if blocking?
        Process.wait(pid)
        return true if $?.exitstatus == 0

        log(
          :warn,
          ct,
          "Hook #{self.class.hook_name} at #{hook_path} exited with #{$?.exitstatus}"
        )

        raise HookFailed.new(self, $?.exitstatus)

      else
        Container::Hook.watch(self, pid)
      end
    end

    def blocking?
      self.class.blocking?
    end

    def hook_path
      self.class.hook_path(ct)
    end

    protected
    # @return [Hash]
    attr_reader :opts

    # Override this method to define environment variables that the script hook
    # will have set.
    # @return [Hash<String, String>]
    def environment
      {
        'OSCTL_HOOK_NAME' => self.class.hook_name.to_s,
        'OSCTL_POOL_NAME' => ct.pool.name,
        'OSCTL_CT_ID' => ct.id,
        'OSCTL_CT_USER' => ct.user.name,
        'OSCTL_CT_GROUP' => ct.group.name,
        'OSCTL_CT_DATASET' => ct.get_run_conf.dataset.to_s,
        'OSCTL_CT_ROOTFS' => ct.get_run_conf.rootfs,
        'OSCTL_CT_LXC_PATH' => ct.lxc_home,
        'OSCTL_CT_LXC_DIR' => ct.lxc_dir,
        'OSCTL_CT_CGROUP_PATH' => ct.cgroup_path,
        'OSCTL_CT_DISTRIBUTION' => ct.get_run_conf.distribution,
        'OSCTL_CT_VERSION' => ct.get_run_conf.version,
        'OSCTL_CT_HOSTNAME' => ct.hostname.to_s,
        'OSCTL_CT_LOG_FILE' => ct.log_path,
      }
    end

    # Override this method to define the program and its arguments that will be
    # execed to invoke the user script hook.
    # @return [Array<String>]
    def executable
      [hook_path]
    end
  end
end
