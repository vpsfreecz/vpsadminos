require 'require_all'

module OsCtl
  module ExportFS
    module Operations
      module Export; end
      module Exportfs; end
      module Runit; end
      module Server; end
    end

    def self.root
      File.realpath(File.join(__dir__, '..', '..'))
    end

    def self.enabled?
      Dir.exist?(RunState::DIR)
    end
  end
end

require_rel 'exportfs/*.rb'
require_rel 'exportfs/config'
require_rel 'exportfs/operations'
