require 'require_all'

module OsCtl
  module ExportFS
    module Operations
      module Export ; end
      module Exportfs ; end
      module Runit ; end
      module Server ; end
    end

    def self.root
      File.realpath(File.join(File.dirname(__FILE__), '..', '..'))
    end
  end
end

require_rel 'exportfs/*.rb'
require_rel 'exportfs/config'
require_rel 'exportfs/operations'
