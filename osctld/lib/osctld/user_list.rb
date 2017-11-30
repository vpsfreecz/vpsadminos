require 'thread'

module OsCtld
  class UserList
    @@instance = nil

    def self.instance
      @@instance = new unless @@instance
      @@instance
    end

    def self.sync(&block)
      instance.sync(&block)
    end

    def self.get(&block)
      instance.get(&block)
    end

    def self.add(user)
      instance.add(user)
    end

    def self.remove(user)
      instance.remove(user)
    end

    def self.find(name, &block)
      instance.find(name)
    end

    private
    def initialize
      @mutex = Mutex.new
      @users = []
      @@instance = self
    end

    public
    def sync(&block)
      if @mutex.owned?
        block.call
      else
        @mutex.synchronize { block.call }
      end
    end

    def get(&block)
      sync do
        if block
          block.call(@users)
        else
          @users.clone
        end
      end
    end

    def add(user)
      sync { @users << user }
    end

    def remove(user)
      sync { @users.delete(user) }
    end

    def find(name, &block)
      sync do
        u = @users.detect { |u| u.name == name }

        if block
          block.call(u)
        else
          u
        end
      end
    end
  end
end
