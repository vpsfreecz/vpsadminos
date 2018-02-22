require_relative '../repo'
require 'gli'

module OsCtl::Repo
  module Cli
    def self.run
      App.run
    end
  end
end

require_relative 'cli/command'
require_relative 'cli/repo'
require_relative 'cli/app'
