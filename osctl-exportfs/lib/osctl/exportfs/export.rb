module OsCtl::ExportFS
  class Export
    # Directory to export from the host namespace
    # @return [String]
    attr_reader :dir

    # Directory to export in the server namespace
    # @return [String]
    attr_reader :as

    # Mask for hosts that can access this export
    # @return [String]
    attr_reader :host

    # NFS options
    # @return [String]
    attr_reader :options

    def self.load(data)
      new(data.transform_keys(&:to_sym))
    end

    # @param export [Hash]
    # @option export [String] :dir
    # @option export [String] :as
    # @option export [String] :host
    # @option export [String] :options
    def initialize(export)
      @dir = export[:dir]
      @as = export[:as] || export[:dir]
      @host = export[:host]
      @options = export[:options]
    end

    def dump
      {
        'dir' => dir,
        'as' => as,
        'host' => host,
        'options' => options
      }
    end
  end
end
