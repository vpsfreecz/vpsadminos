require 'osctl/exportfs/operations/base'

module OsCtl::ExportFS
  class Operations::Server::List < Operations::Base
    def initialize; end

    def execute
      ret = []

      Dir.entries(RunState::SERVERS).each do |v|
        next if %w[. ..].include?(v)

        ret << OsCtl::ExportFS::Server.new(v)
      end

      ret
    end
  end
end
