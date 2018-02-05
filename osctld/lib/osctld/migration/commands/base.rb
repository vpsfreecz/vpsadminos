module OsCtld
  class Migration::Commands::Base < OsCtld::Commands::Base
    def self.handle(name)
      Migration::Command.register(name, self)
    end
  end
end
