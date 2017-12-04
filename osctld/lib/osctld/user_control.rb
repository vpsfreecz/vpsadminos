module OsCtld
  module UserControl
    def self.setup
      UserList.get do |users|
        users.each { |u| Supervisor.start_server(u) }
      end
    end

    def self.stop
      Supervisor.stop_all
    end
  end
end
