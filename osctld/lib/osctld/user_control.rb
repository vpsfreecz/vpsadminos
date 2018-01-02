module OsCtld
  module UserControl
    def self.stop
      Supervisor.stop_all
    end
  end
end
