require 'vpsadminos-converter/net_interface/base'

module VpsAdminOS::Converter
  class NetInterface::Routed < NetInterface::Base
    type :routed

    attr_accessor :routes

    def dump
      super.merge(
        'routes' => Hash[routes.map do |ip_v, addrs|
          ["v#{ip_v}", addrs.map(&:to_string)]
        end]
      )
    end
  end
end
