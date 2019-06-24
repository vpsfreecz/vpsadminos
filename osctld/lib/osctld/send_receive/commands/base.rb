require 'osctld/commands/base'

module OsCtld
  class SendReceive::Commands::Base < OsCtld::Commands::Base
    def self.handle(name)
      SendReceive::Command.register(name, self)
    end
  end
end
