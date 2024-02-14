require 'libosctl'
require 'osctl/image/operations/base'

module OsCtl::Image
  class Operations::Config::ParseList < Operations::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @return [String]
    attr_reader :base_dir

    # @return [Symbol]
    attr_reader :type

    # @param base_dir [String]
    # @param type [:builder, :image]
    def initialize(base_dir, type)
      super()
      @base_dir = base_dir
      @type = type
    end

    # @return [Array<String>]
    # @raise [OsCtl::Lib::SystemCommandFailed]
    def execute
      syscmd([
        File.join(base_dir, 'bin', 'config'),
        type.to_s,
        'list'
      ].join(' ')).output.split("\n")
    end
  end
end
