require 'libosctl'

module OsCtld
  class Hook::Base
    class << self
      attr_reader :hook_name, :user_hook_name

      # Register hook under a name
      # @param event_class [Class]
      # @param hook_name [Symbol]
      def hook(event_class, hook_name, hook_class)
        @hook_name = hook_name
        @user_hook_name = hook_name.to_s.gsub(/_/, '-')
        Hook.register(event_class, hook_name, hook_class)
      end

      # Mark the hook as blocking or async, defaults to async
      # @param v [Boolean] `true` for blocking, `false` for async
      def blocking(v)
        @blocking = v
      end

      def blocking?
        @blocking || false
      end
    end

    include OsCtl::Lib::Utils::Log

    # @return [Class]
    attr_reader :event_instance

    def initialize(event_instance, opts)
      @event_instance = event_instance
      @opts = opts
      setup
    end

    def setup ; end

    # Execute the user script hook.
    #
    # For blocking hooks, this method waits for the script hook to exit. If it
    # exits with non-zero exit status, exception {HookFailed} is raised. Async
    # hooks return immediately and their exit status has no meaning.
    #
    # @param hook_path [String]
    def exec(hook_path)
      log(
        :info,
        event_instance,
        "Executing hook #{self.class.hook_name} at #{hook_path}"
      )

      env = environment

      pid = Process.fork do
        ENV.delete_if { |k,_| k != 'PATH' }
        env.each { |k, v| ENV[k] = v }

        Process.exec(*executable(hook_path))
      end

      if blocking?
        Process.wait(pid)
        return true if $?.exitstatus == 0

        log(
          :warn,
          event_instance,
          "Hook #{self.class.hook_name} at #{hook_path} exited with #{$?.exitstatus}"
        )

        raise HookFailed.new(self, hook_path, $?.exitstatus)

      else
        Hook.watch(self, hook_path, pid)
      end
    end

    def blocking?
      self.class.blocking?
    end

    protected
    # @return [Hash]
    attr_reader :opts

    # Override this method to define environment variables that the script hook
    # will have set.
    # @return [Hash<String, String>]
    def environment
      {
        'OSCTL_HOOK_NAME' => self.class.user_hook_name,
      }
    end

    # Override this method to define the program and its arguments that will be
    # execed to invoke the user script hook.
    # @param hook_path [String]
    # @return [Array<String>]
    def executable(hook_path)
      [hook_path]
    end
  end
end
