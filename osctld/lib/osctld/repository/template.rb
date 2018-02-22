module OsCtld
  class Repository::Template
    ATTRS = %i(vendor variant arch distribution version tags)
    attr_reader :vendor, :variant, :arch, :distribution, :version, :tags

    # @param attrs [Hash]
    def initialize(attrs)
      ATTRS.each do |attr|
        instance_variable_set("@#{attr}", attrs[attr])
      end

      @cached = attrs[:cached].any?
    end

    def cached?
      @cached
    end

    def dump
      ret = {}
      ATTRS.each { |attr| ret[attr] = send(attr) }
      ret[:cached] = cached?
      ret
    end
  end
end
