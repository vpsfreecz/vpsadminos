module Overcommit::Hook::PreCommit
  class Nixfmt < Base
    def run
      nix_files = applicable_files.select { |v| v.end_with?('.nix') }
      return :pass if nix_files.empty?

      output = `nixfmt --check #{nix_files.map { |v| "\"#{v}\"" }.join(' ')}`
      return :pass if $?.exitstatus == 0

      [:fail, output]
    end
  end
end
