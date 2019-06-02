require 'require_all'

module OsCtl
  module Template
    module Operations
      module Builder ; end
      module Config; end
      module Execution ; end
      module Nix ; end
      module Repository ; end
      module Template ; end
      module Test ; end
    end
  end
end

require_rel 'template/*.rb'
require_rel 'template/operations'
