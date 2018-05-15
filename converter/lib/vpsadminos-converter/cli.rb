require 'vpsadminos-converter'

module VpsAdminOS::Converter
  module Cli
    module Vz6 ; end

    def self.run
      App.run
    end
  end
end

require_rel 'cli'
