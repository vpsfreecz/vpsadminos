require 'require_all'
require 'prometheus_ext/client/registry'

module OsCtl
  module Exporter
    # @return [Registry]
    def self.registry
      @registry ||= Registry.new
    end
  end
end

require_rel 'exporter/*.rb'
