require 'concurrent'

module OsCtld
  class Command
    include OsCtl::Lib::Utils::Log

    @@commands = {}
    @@cmd_id = Concurrent::AtomicFixnum.new(0)

    def self.register(name, klass)
      @@commands[self] ||= {}

      if @@commands[self].has_key?(name)
        raise "Command '#{name}' is already handled by class '#{@@commands[self][name]}'"
      end

      @@commands[self][name] = klass
    end

    def self.find(handle)
      @@commands[self][handle]
    end

    def self.get_id
      @@cmd_id.increment
    end
  end
end
