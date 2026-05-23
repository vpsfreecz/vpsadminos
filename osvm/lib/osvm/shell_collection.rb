module OsVm
  class ShellCollection
    include Enumerable

    def initialize(machine, shells)
      @machine = machine
      @shells = shells.transform_keys(&:to_s).freeze
    end

    def [](name)
      fetch(name)
    end

    def fetch(name, *default)
      raise ArgumentError, 'wrong number of arguments' if default.length > 1

      key = name.to_s
      return shells.fetch(key) if shells.has_key?(key)
      return yield(name) if block_given?
      return default.first if default.length == 1

      raise KeyError, "unknown shell #{name.inspect} for machine #{machine.name}"
    end

    def key?(name)
      shells.has_key?(name.to_s)
    end

    alias include? key?
    alias member? key?

    def keys
      shells.keys
    end

    def each(&)
      shells.each(&)
    end

    def to_h
      shells.dup
    end

    protected

    attr_reader :machine, :shells
  end
end
