require 'thread'

module OsCtld
  class UserControl::Supervisor
    @@instance = nil

    def self.instance
      @@instance = new unless @@instance
      @@instance
    end

    class << self
      %i(start_server stop_server stop_all).each do |v|
        define_method(v) do |*args, &block|
          instance.send(v, *args, &block)
        end
      end
    end

    private
    def initialize
      @mutex = Mutex.new
      @servers = {}
    end

    public
    def start_server(user)
      sync do
        s = UserControl::Server.new
        t = Thread.new { s.start(user) }

        @servers[user.name] = [s, t]
      end
    end

    def stop_server(user)
      sync do
        s, t = @servers[user.name]
        s.stop
        t.join
      end
    end

    def stop_all
      sync do
        @servers.each { |user, st| st[0].stop }
        @servers.each { |user, st| st[1].join }
      end
    end

    private
    def sync
      @mutex.synchronize { yield }
    end
  end
end
