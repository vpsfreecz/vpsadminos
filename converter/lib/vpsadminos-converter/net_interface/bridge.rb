require 'vpsadminos-converter/net_interface/base'

module VpsAdminOS::Converter
  class NetInterface::Bridge < NetInterface::Base
    type :bridge

    attr_accessor :link

    def dump
      super.merge('link' => link)
    end
  end
end
