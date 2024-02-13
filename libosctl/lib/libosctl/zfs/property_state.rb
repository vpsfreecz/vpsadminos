module OsCtl::Lib
  # Store a set of configured ZFS properties, then apply it to another dataset
  class Zfs::PropertyState
    include Utils::Log
    include Utils::System

    # @return [Hash]
    attr_reader :properties

    # @return [Hash]
    attr_reader :options

    def initialize
      @properties = {}
      @options = {}
    end

    def clean
      @properties.clear
      @options.clear
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
        options[prop] = to_option(prop, value)
      end
    end

    # @param dataset [Zfs::Dataset]
    def apply_to(dataset)
      zfs(
        :set,
        option_strings.map { |opt| "-o #{opt}" }.join(' '),
        dataset
      )
    end

    # @return [Array<String>]
    def option_strings
      options.map { |k, v| "\"#{k}=#{v}\"" }
    end

    protected

    # @param property [String]
    # @param value [String]
    def to_option(property, value)
      return 'none' if %w[quota refquota].include?(property) && value.to_i == 0

      value
    end
  end
end
