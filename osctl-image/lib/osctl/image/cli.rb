require 'osctl/image'
require 'require_all'

module OsCtl::Image
  module Cli
    def self.run
      App.run
    end
  end
end

require_rel 'cli'
