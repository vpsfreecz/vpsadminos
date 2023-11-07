module OsCtl::Lib
  module Logger
    # @param type [Symbol] `:stdout`, `:io`, `:syslog` or `:none`
    # @param opts [Hash]
    # @option opts [IO] :io
    # @option opts [String] :name program name for syslog
    # @option opts [String] :facility syslog facility, see man syslog(3), in lower case,
    #                                 without `LOG_` prefix
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
        @logger = Syslog::Logger.new(
          opts[:name] || File.basename($0),
          Syslog.const_get(:"LOG_#{(opts[:facility] || 'daemon').upcase}")
        )

      when :none
        @logger = :none

      else
        fail "unsupported logger type '#{type}'"
      end
    end

    # @return [Logger, nil]
    def self.get
      @logger == :none ? nil : @logger
    end

    def self.log(severity, msg)
      return if @logger == :none
      @logger.send(severity, msg)
      STDOUT.flush if @logger.is_a?(::Logger)
    end
  end
end
