require 'require_all'
require 'prometheus_ext/client/registry'

module OsCtl
  module Exporter
    module Formats ; end

    # @return [MultiRegistry]
    def self.registry
      @registry ||= MultiRegistry.new
    end
  end
end

require_rel 'exporter/*.rb'
require_rel 'exporter/formats'
require 'prometheus_ext/middleware/exporter'
