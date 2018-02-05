module OsCtld
  class UserControl::Commands::Base < OsCtld::Commands::Base
    def self.handle(name)
      UserControl::Command.register(name, self)
    end

    def self.run(user, opts = {})
      c = new(user, opts)
      c.execute
    end

    attr_reader :user

    def initialize(user, opts)
      @user = user
      @opts = opts
    end

    protected
    def owns_ct?(ct)
      ct.user == user
    end
  end
end
