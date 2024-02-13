require 'etc'
require 'singleton'

module OsCtl::Lib
  class SysConf
    include Singleton

    VALUES = %i[page_size tics_per_second]

    class << self
      VALUES.each do |v|
        define_method(v) { instance.send(v) }
      end
    end

    def initialize
      @values = {}
    end

    # @param name [Symbol]
    def get(name)
      unless VALUES.include?(name)
        raise ArgumentError, "#{name.inspect} is not known"
      end

      @values[name] ||= send(:"get_#{name}")
    end

    VALUES.each do |v|
      define_method(v) { get(v) }
    end

    protected

    def get_page_size
      Etc.sysconf(Etc::SC_PAGESIZE)
    end

    def get_tics_per_second
      Etc.sysconf(Etc::SC_CLK_TCK)
    end
  end
end
