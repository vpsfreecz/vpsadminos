module OsCtld
  class Mount
    PARAMS = %i(fs mountpoint type opts)
    attr_reader :fs, :mountpoint, :type, :opts

    # Load from config
    def self.load(cfg)
      new(* PARAMS.map { |v| cfg[v.to_s] })
    end

    def initialize(fs, mountpoint, type, opts)
      @fs = fs
      @mountpoint = mountpoint
      @type = type
      @opts = opts
    end

    # Export to client
    def export
      Hash[PARAMS.map { |v| [v, instance_variable_get(:"@#{v}")] }]
    end

    # Dump to config
    def dump
      Hash[PARAMS.map { |v| [v.to_s, instance_variable_get(:"@#{v}")] }]
    end
  end
end
