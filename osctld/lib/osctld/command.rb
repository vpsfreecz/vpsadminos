module OsCtld
  class Command
    include Utils::Log

    @@commands = {}

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
  end
end
