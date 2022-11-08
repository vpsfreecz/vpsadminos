require 'require_all'
require 'prometheus_ext/client/registry'

module OsCtl
  module Exporter
    # @return [MultiRegistry]
    def self.registry
      @registry ||= MultiRegistry.new
    end
  end
end

require_rel 'exporter/*.rb'
