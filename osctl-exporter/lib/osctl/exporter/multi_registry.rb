module OsCtl::Exporter
  # Encapsulate multiple registries and present them as one
  class MultiRegistry
    def initialize
      @registries = {}
    end

    # @oaram handle [any]
    # @return [Registry]
    def new_registry(handle)
      @registries[handle] = Registry.new
    end

    # Disallow write operations
    %i(register unregister counter summary gauge histogram).each do |m|
      define_method(m) do |*args, **kwargs|
        fail 'not supported on MultiRegistry'
      end
    end

    def exist?(name)
      @registries.each_value do |r|
        return true if r.exist?(name)
      end

      false
    end

    def get(name)
      @registries.each_value do |r|
        v = r.get(name)
        return v if v
      end

      nil
    end

    def metrics
      ret = []

      @registries.each_value do |r|
        ret.concat(r.metrics)
      end

      ret
    end
  end
end
