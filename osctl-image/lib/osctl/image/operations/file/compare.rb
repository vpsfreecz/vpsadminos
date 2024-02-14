require 'libosctl'
require 'osctl/image/operations/base'

module OsCtl::Image
  class Operations::File::Compare < Operations::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @return [Array]
    attr_reader :files

    # @param file1 [String]
    # @param file2 [String]
    def initialize(file1, file2)
      super()
      @files = [file1, file2]
    end

    # @return [Boolean] true if the files are same
    def execute
      ret = syscmd("cmp -s \"#{@files[0]}\" \"#{@files[1]}\"", valid_rcs: [1, 2])
      ret.exitstatus == 0
    end
  end
end
