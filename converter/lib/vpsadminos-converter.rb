require 'libosctl'
require 'require_all'

module VpsAdminOS
  module Converter
    module Vz6; end
  end
end

require_rel 'vpsadminos-converter/*.rb'
require_rel 'vpsadminos-converter/net_interface'
