require 'osctl'

module OsCtl
  module Cli
    module Top ; end

    def self.run
      App.run
    end
  end
end

require_rel 'cli'
