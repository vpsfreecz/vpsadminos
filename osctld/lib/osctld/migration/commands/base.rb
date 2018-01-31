module OsCtld
  class Migration::Commands::Base < Commands::Base
    def self.handle(name)
      Migration::Command.register(name, self)
    end
  end
end
