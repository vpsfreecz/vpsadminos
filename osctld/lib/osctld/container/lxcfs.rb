module OsCtld
  class Container::Lxcfs
    # @param cfg [Hash]
    def self.load(cfg)
      new(
        enable: cfg.fetch('enable', true),
      )
    end

    include Lockable

    # @return [Boolean]
    attr_reader :enable

    def initialize(enable: true)
      init_lock
      @enable = enable
    end

    def configure
      exclusively do
        @enable = true
      end
    end

    def disable
      exclusively do
        @enable = false
      end
    end

    def dump
      inclusively do
        {
          'enable' => enable,
        }
      end
    end

    def dup
      ret = super()
      ret.init_lock
      ret
    end
  end
end
