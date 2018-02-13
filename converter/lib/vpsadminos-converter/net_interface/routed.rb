module VpsAdminOS::Converter
  class NetInterface::Routed < NetInterface::Base
    type :routed

    attr_accessor :via

    def dump
      super.merge(
        'via' => Hash[via.map { |k,v| [k, v.to_string] }]
      )
    end
  end
end
