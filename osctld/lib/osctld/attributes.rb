require 'osctld/lockable'

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

    include Lockable

    def initialize
      init_lock
      @attrs = {}
    end

    # Set an attribute
    def set(name, value)
      k = key(name)
      raise 'invalid attribute name' if /^[^:]+:.+$/ !~ k

      exclusively { attrs[k] = value }
    end

    # Unset an attribute
    def unset(name)
      exclusively { attrs.delete(key(name)) }
    end

    # Update attributes
    # @param new_attrs [Hash]
    def update(new_attrs)
      exclusively { new_attrs.each { |k, v| set(key(k), v) } }
    end

    def []=(name, value)
      set(key(name), value)
    end

    def [](name)
      inclusively { attrs[key(name)] }
    end

    # Dump to config
    def dump
      inclusively { attrs.clone }
    end

    # Export attributes to client
    def export
      inclusively { attrs.transform_keys { |k| k.to_sym } }
    end

    def dup
      ret = super
      ret.init_lock
      ret
    end

    protected

    attr_reader :attrs

    def key(v)
      v.to_s
    end
  end
end
