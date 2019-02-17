require 'osctl'

module OsCtl
  module Cli
    module Completion ; end
    module Ps ; end
    module Top ; end

    def self.run
      App.run
    end
  end
end

require_rel 'cli'
