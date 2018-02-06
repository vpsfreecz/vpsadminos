require_relative '../vpsadminos-converter'

module VpsAdminOS::Converter
  module Cli
    def self.run
      App.run
    end
  end
end

require_relative 'cli/command'
require_relative 'cli/app'
