require 'osctld/lockable'

module OsCtld
  class Container::RawConfigs
    KEYS = %i[lxc].freeze

    include Lockable

    # @param config [Hash<String, String>]
    def self.load(config)
      new(config.transform_keys(&:to_sym))
    end

    # @param configs [Hash<Symbol, String>]
    def initialize(configs = {})
      init_lock
      @data = {}
      KEYS.each { |k| @data[k] = configs[k] }
    end

    KEYS.each do |k|
      define_method(k) do
        inclusively { @data[k] }
      end

      define_method(:"#{k}=") do |v|
        exclusively { @data[k] = v }
      end
    end

    def dump
      inclusively do
        if @data.empty?
          nil
        else
          ret = {}

          @data.each do |k, v|
            ret[k.to_s] = v if v
          end

          ret
        end
      end
    end

    def dup
      ret = super
      ret.init_lock
      ret.instance_variable_set('@data', @data.clone)
      ret
    end
  end
end
