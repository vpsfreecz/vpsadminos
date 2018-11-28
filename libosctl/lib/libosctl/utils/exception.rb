module OsCtl::Lib
  module Utils::Exception
    # Return a new backtrace with removed `/nix/store/...` prefixes
    # @param backtrace [Array<String>]
    # @return [Array<String>]
    def denixstorify(backtrace)
      backtrace.map do |line|
        line.sub(
          /^\/nix\/store\/[^\/]+\/lib\/ruby\/gems\/\d+\.\d+\.\d+\/gems\//,
          ''
        )
      end
    end
  end
end
