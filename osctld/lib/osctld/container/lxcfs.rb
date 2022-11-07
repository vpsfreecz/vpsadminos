module OsCtld
  class Container::Lxcfs
    # @param cfg [Hash]
    def self.load(cfg)
      new(
        enable: cfg.fetch('enable', true),
        loadavg: cfg.fetch('loadavg', true),
        cfs: cfg.fetch('cfs', true),
      )
    end

    include Lockable

    # @return [Boolean]
    attr_reader :enable

    # @return [Boolean]
    attr_reader :loadavg

    # @return [Boolean]
    attr_reader :cfs

    def initialize(enable: true, loadavg: true, cfs: true)
      init_lock
      @enable = enable
      @loadavg = loadavg
      @cfs = cfs
    end

    def configure(loadavg: true, cfs: true)
      exclusively do
        @enable = true
        @loadavg = loadavg
        @cfs = cfs
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
          'loadavg' => loadavg,
          'cfs' => cfs,
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
