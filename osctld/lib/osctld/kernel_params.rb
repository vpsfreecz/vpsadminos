require 'singleton'

module OsCtld
  # Interface to kernel command line parameters
  class KernelParams
    include Singleton

    class << self
      %i[params import_pools? autostart_cts?].each do |m|
        define_method(m) do |*args, &block|
          instance.send(m, *args, &block)
        end
      end
    end

    attr_reader :params

    def initialize
      @cache = {}
      @params = File.read('/proc/cmdline').strip.split
    end

    # Check if parameter is set
    # @param name [String]
    def include?(name)
      params.include?(name)
    end

    # Extract key-value parameter
    # @param k [String] parameter name
    # @param default_v [String] default value
    # @return [String]
    def read_kv(k, default_v)
      params.each do |param|
        eq = param.index('=')
        next if eq.nil?

        param_k = param[0..eq - 1]
        next if param_k != k

        return param[eq + 1..]
      end

      default_v
    end

    # Check parameter osctl.pools
    #
    # Enabled by default.
    def import_pools?
      cache(:pools) { read_kv('osctl.pools', '1') == '1' }
    end

    # Check parameter osctl.autostart
    #
    # Enabled by default.
    def autostart_cts?
      cache(:autostart) { read_kv('osctl.autostart', '1') == '1' }
    end

    protected

    def cache(name)
      return @cache[name] if @cache.has_key?(name)

      @cache[name] = yield
    end
  end
end
