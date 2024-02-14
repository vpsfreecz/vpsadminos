require 'libosctl'
require 'osctl/image/operations/base'

module OsCtl::Image
  class Operations::Config::ParseAttrs < Operations::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @return [String]
    attr_reader :base_dir

    # @return [Symbol]
    attr_reader :type

    # @return [String]
    attr_reader :name

    # @param base_dir [String]
    # @param type [:builder, :image]
    # @param name [String]
    def initialize(base_dir, type, name)
      super()
      @base_dir = base_dir
      @type = type
      @name = name
    end

    # @return [Hash]
    # @raise [OsCtl::Lib::SystemCommandFailed]
    def execute
      ret = {}

      syscmd([
        File.join(base_dir, 'bin', 'config'),
        type.to_s,
        'show',
        name
      ].join(' ')).output.split("\n").each do |line|
        eq = line.index('=')
        next if eq.nil?

        var = line[0..eq - 1]
        val = line[eq + 1..]

        next if val.empty?

        ret[var] = val
      end

      ret
    end
  end
end
