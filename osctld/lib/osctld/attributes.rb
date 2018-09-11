module OsCtld
  # Storage of user attributes
  class Attributes
    # Load attributes from config
    # @param cfg [Hash]
    def self.load(cfg)
      ret = new
      cfg.each { |k, v| ret.set(k, v) }
      ret
    end

    def initialize
      @attrs = {}
    end

    # Set an attribute
    def set(name, value)
      k = key(name)
      fail 'invalid attribute name' if /^[^:]+:.+$/ !~ k

      attrs[k] = value
    end

    # Unset an attribute
    def unset(name)
      attrs.delete(key(name))
    end

    # Update attributes
    # @param new_attrs [Hash]
    def update(new_attrs)
      new_attrs.each { |k, v| set(key(k), v) }
    end

    def []=(name, value)
      set(key(name), value)
    end

    def [](name)
      attrs[key(name)]
    end

    # Dump to config
    def dump
      attrs
    end

    # Export attributes to client
    def export
      Hash[ attrs.map { |k, v| [k.to_sym, v] } ]
    end

    protected
    attr_reader :attrs

    def key(v)
      v.to_s
    end
  end
end
