module TestRunner
  module Hook
    # @param name [Symbol]
    def self.register(name)
      @hooks ||= {}
      @hooks[name] ||= []
    end

    # @param name [Symbol]
    def self.subscribe(name, &block)
      subscribers = (@hooks || {})[name]

      raise "hook #{name.inspect} not registered" if subscribers.nil?

      subscribers << block
      nil
    end

    # @param name [Symbol]
    # @param args [Array]
    # @param kwargs [Hash]
    # @return [any]
    def self.call(name, args: [], kwargs: {})
      return if @hooks.nil?

      subscribers = @hooks[name]
      return if subscribers.empty?

      subscribers.inject(nil) do |ret, sub|
        hook_kwargs = kwargs.merge(return_value: ret)
        sub.call(*args, **hook_kwargs)
      end
    end
  end
end
