module OsCtld
  module Logger
    def self.setup(type)
      case type
      when :stdout
        require 'logger'
        @logger = ::Logger.new(STDOUT)

      when :syslog
        require 'syslog/logger'
        @logger = Syslog::Logger.new('osctld', Syslog::LOG_LOCAL2)
      end
    end

    def self.log(severity, msg)
      @logger.send(severity, msg)
    end
  end
end
