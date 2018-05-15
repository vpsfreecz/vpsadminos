require 'require_all'

module OsCtl
  module Lib
    module Exporter ; end
    module Utils ; end
    module Zfs ; end
  end
end

require_rel 'libosctl/utils'
require_rel 'libosctl'
