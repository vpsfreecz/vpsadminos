module VpsAdminOS::Converter
  class RouteViaMissing < StandardError
    attr_reader :ip_v

    def initialize(ip_v)
      @ip_v = ip_v
    end
  end
end
