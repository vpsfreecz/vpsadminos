module OsCtl::Lib
  module Logger
    # @param type [Symbol] `:stdout`, `:io`, `:syslog` or `:none`
    # @param opts [Hash]
    # @option opts [IO] :io
    def self.setup(type, opts = {})
      case type
      when :stdout
        require 'logger'
        @logger = ::Logger.new(STDOUT)

      when :io
        require 'logger'
        @logger = ::Logger.new(opts[:io])

      when :syslog
        require 'syslog/logger'
        @logger = Syslog::Logger.new('osctld', Syslog::LOG_LOCAL2)

      when :none
        @logger = :none

      else
        fail "unsupported logger type '#{type}'"
      end
    end

    def self.log(severity, msg)
      return if @logger == :none
      @logger.send(severity, msg)
      STDOUT.flush if @logger.is_a?(::Logger)
    end
  end
end
