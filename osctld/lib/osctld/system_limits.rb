require 'libosctl'
require 'osctld/lockable'
require 'singleton'

module OsCtld
  # Configurator of system-level resource limits
  class SystemLimits
    FILE_MAX_PATH = '/proc/sys/fs/file-max'
    FILE_MAX_DEFAULT = 1024*1024

    class << self
      %i(ensure_nofile).each do |m|
        define_method(m) do |*args, &block|
          instance.send(m, *args, &block)
        end
      end
    end

    include Singleton
    include Lockable
    include OsCtl::Lib::Utils::Log

    def initialize
      init_lock
      @values = {}

      ensure_nofile(FILE_MAX_DEFAULT)
    end

    # @param v [Integer]
    def ensure_nofile(v)
      exclusively do
        values['nofile'] ||= File.read(FILE_MAX_PATH).strip.to_i

        if values['nofile'] < v
          log(:info, "Setting #{FILE_MAX_PATH} to #{v}")
          File.write(FILE_MAX_PATH, v.to_s)
          values['nofile'] = v
        end
      end
    end

    def log_type
      'system-limits'
    end

    protected
    attr_reader :values
  end
end
