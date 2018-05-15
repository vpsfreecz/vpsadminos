require 'osctl/repo'

module OsCtl::Repo
  module Cli
    def self.run
      App.run
    end
  end
end

require_rel 'cli'
