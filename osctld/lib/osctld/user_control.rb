module OsCtld
  module UserControl
    def self.setup
      DB::Users.get do |users|
        users.each { |u| Supervisor.start_server(u) }
      end
    end

    def self.stop
      Supervisor.stop_all
    end
  end
end
