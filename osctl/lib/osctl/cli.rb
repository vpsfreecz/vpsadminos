require_relative '../osctl'
require_relative 'cli/output_formatter'
require_relative 'cli/command'
require_relative 'cli/app'

module OsCtl
  module Cli
    def self.run
      App.run
    end
  end
end
