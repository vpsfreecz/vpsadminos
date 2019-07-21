module OsCtl::Lib
  # Store a set of configured ZFS properties, then apply it to another dataset
  class Zfs::PropertyState
    include Utils::Log
    include Utils::System

    # @return [Hash]
    attr_reader :properties

    def initialize
      @properties = {}
    end

    def clean
      @properties.clear
    end

    # @param dataset [Zfs::Dataset]
    def read_from(dataset)
      zfs(
        :get,
        '-Hp -o property,value -s local,received all',
        dataset
      ).output.strip.split("\n").each do |line|
        prop, value = line.split
        properties[prop] = value
      end
    end

    # @param dataset [Zfs::Dataset]
    def apply_to(dataset)
      zfs(
        :set,
        options.map { |opt| "-o #{opt}" }.join(" "),
        dataset,
      )
    end

    # @return [Array<String>]
    def options
      properties.map { |k, v| "\"#{k}=#{v}\"" }
    end
  end
end
