require 'libosctl'

module OsCtld
  module Container::Hook
    extend OsCtl::Lib::Utils::Log

    # Register hook
    # @param name [Symbol]
    # @param klass [Class]
    def self.register(name, klass)
      @hooks ||= {}
      @hooks[name] = klass
    end

    # @return [Array<Symbol>]
    def self.hooks
      @hooks
    end

    # Check if a hook with given name exists
    # @param name [Symbol]
    def self.exist?(name)
      @hooks.has_key?(name)
    end

    # Run user-defined script hook for container
    #
    # See module {Container::Hooks} for available hook names and options.
    #
    # @param ct [Container]
    # @param name [Symbol] hook name
    # @param opts [Hash] hook options
    def self.run(ct, name, opts = {})
      @hooks[name].run(ct, opts)
    end

    # Spawn a thread that will wait for the results of an async hook
    # @param hook [Container::Hooks::Base]
    # @param pid [Integer]
    def self.watch(hook, pid)
      Thread.new do
        Process.wait(pid)
        next if $?.exitstatus == 0

        log(
          :warn,
          hook.ct,
          "Hook #{hook.class.hook_name} at #{hook.hook_path} exited with #{$?.exitstatus}"
        )
      end
    end
  end
end
