require 'osctl'

module OsCtl
  module Cli
    module Completion ; end
    module Ps ; end
    module Top ; end

    def self.run
      App.run
    end

    # @return [:unicode, :ascii]
    def self.encoding
      if ENV['LANG'] && /UTF-8/i =~ ENV['LANG']
        :unicode
      else
        :ascii
      end
    end
  end
end

require_rel 'cli'
