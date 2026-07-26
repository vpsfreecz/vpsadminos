require 'libosctl'

module OsCtld
  module Hook
    extend OsCtl::Lib::Utils::Log

    # Register hook
    # @param event_class [Class]
    # @param hook_name [Symbol]
    # @param hook_class [Class]
    def self.register(event_class, hook_name, hook_class)
      @hooks ||= {}
      @hooks[event_class] ||= {}
      @hooks[event_class][hook_name] = hook_class
    end

    # @param event_class [Class]
    # @return [Hash<Symbol, Class>]
    def self.hooks(event_class)
      @hooks[event_class]
    end

    # Check if a hook with given name exists
    # @param event_class [Class]
    # @param hook_name [Symbol]
    def self.exist?(event_class, hook_name)
      @hooks[event_class].has_key?(hook_name)
    end

    # Run user-defined script hook
    #
    # See module {Container::Hooks} for available hook names and options.
    #
    # @param event_instance [Class]
    # @param hook_name [Symbol] hook name
    # @param opts [Hash] hook options
    def self.run(event_instance, hook_name, **opts)
      Hook::Manager.run(event_instance, @hooks[event_instance.class][hook_name], opts)
    end

    # Spawn a thread that will wait for the results of an async hook
    # @param hook [Hook::Base]
    # @param hook_path [String]
    # @param pid [Integer]
    # @param lifecycle_owner [Hash, nil]
    def self.watch(hook, hook_path, pid, lifecycle_owner: nil)
      Thread.new do
        _, status = Process.wait2(pid)
        next if status.exitstatus == 0

        log(
          :warn,
          hook.event_instance,
          "Hook #{hook.class.hook_name} at #{hook_path} exited with #{status.exitstatus}"
        )
      ensure
        hook.send(:finish_lifecycle_process, lifecycle_owner)
      end
    end
  end
end
