require 'osctl/exportfs'
require 'require_all'

module OsCtl::ExportFS
  module Cli
    def self.run
      App.run
    end
  end
end

require_rel 'cli'
