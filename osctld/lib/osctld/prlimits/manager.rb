require 'osctld/lockable'

module OsCtld
  class PrLimits::Manager
    include Lockable

    # Load prlimits from config
    # @param ct [Container]
    # @param cfg [Array]
    def self.load(ct, cfg)
      entries = if cfg.is_a?(Array)
                  cfg.map do |v|
                    [v['name'], PrLimits::PrLimit.load(v['name'], v)]
                  end
                else
                  cfg.map { |k, v| [k, PrLimits::PrLimit.load(k, v)] }
                end

      new(ct, entries: entries.to_h)
    end

    # Create new resource limits with default values
    # @param ct [Container]
    def self.default(ct)
      new(ct, entries: {
        'nofile' => PrLimits::PrLimit.new('nofile', 1024, SystemLimits::FILE_MAX_DEFAULT)
      })
    end

    # @param ct [Container]
    def initialize(ct, entries: {})
      init_lock

      @ct = ct
      @prlimits = entries
    end

    # @param name [String]
    # @param soft [Integer]
    # @param hard [Integer]
    def set(name, soft, hard)
      exclusively do
        if prlimits.has_key?(name)
          prlimits[name].set(soft, hard)
        else
          prlimits[name] = PrLimits::PrLimit.new(name, soft, hard)
        end
      end

      ct.save_config
      ct.lxc_config.configure_prlimits
      SystemLimits.ensure_nofile(hard) if name == 'nofile'
    end

    # @param name [String]
    def unset(name)
      exclusively { prlimits.delete(name) }
      ct.save_config
      ct.lxc_config.configure_prlimits
    end

    # @param name [String]
    # @return [PrLimits::PrLimit, nil]
    def [](name)
      inclusively { prlimits[name] }
    end

    # @param name [String]
    def contains?(name)
      inclusively { prlimits.has_key?(name) }
    end

    # @yieldparam name [String]
    # @yieldparam prlimit [PrLimits::PrLimit]
    def each(&block)
      inclusively { prlimits.each(&block) }
    end

    # Dump to config
    def dump
      inclusively { prlimits.to_h { |k, v| [k, v.dump] } }
    end

    def export
      inclusively do
        prlimits.to_h { |k, v| [k, v.export] }
      end
    end

    def dup(new_ct)
      ret = super()
      ret.instance_variable_set('@ct', new_ct)
      ret.instance_variable_set('@prlimits', prlimits.map(&:clone))
      ret
    end

    protected

    attr_reader :ct, :prlimits
  end
end
