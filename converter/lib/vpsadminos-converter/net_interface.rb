module VpsAdminOS::Converter
  module NetInterface
    def self.register(type, klass)
      @types ||= {}
      @types[type] = klass
    end

    def self.for(type)
      @types[type]
    end
  end
end

require_relative 'net_interface/base'
require_relative 'net_interface/bridge'
require_relative 'net_interface/routed'
