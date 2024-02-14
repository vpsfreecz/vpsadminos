require 'vpsadminos-converter/net_interface'

module VpsAdminOS::Converter
  class NetInterface::Base
    def self.type(name = nil)
      if name
        NetInterface.register(name, self)
        @type = name

      else
        @type
      end
    end

    attr_accessor :name, :hwaddr
    attr_reader :type, :ip_addresses

    def initialize(name, hwaddr = nil)
      @name = name
      @hwaddr = hwaddr
      @type = self.class.type
      @ip_addresses = { 4 => [], 6 => [] }
    end

    def dump
      {
        'type' => type.to_s,
        'name' => name,
        'hwaddr' => hwaddr,
        'ip_addresses' => ip_addresses.to_h do |v, ips|
          ["v#{v}", ips.map(&:to_string)]
        end
      }
    end
  end
end
