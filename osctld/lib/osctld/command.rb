module OsCtld
  class Command
    include Utils::Log

    @@commands = {}

    def self.register(name, klass)
      if @@commands.has_key?(name)
        raise "Command '#{name}' is already handled by class '#{@@commands[name]}'"
      end

      @@commands[name] = klass
    end

    def self.find(handle)
      @@commands[handle]
    end
  end
end
