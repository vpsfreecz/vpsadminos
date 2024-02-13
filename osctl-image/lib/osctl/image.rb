require 'require_all'

module OsCtl
  module Image
    module Operations
      module Builder; end
      module Config; end
      module Execution; end
      module File; end
      module Image; end
      module Nix; end
      module Repository; end
      module Test; end
    end
  end
end

require_rel 'image/*.rb'
require_rel 'image/operations'
