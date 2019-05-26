require 'osctl/template'
require 'require_all'

module OsCtl::Template
  module Cli
    def self.run
      App.run
    end
  end
end

require_rel 'cli'
