module VpsAdminOS::Converter
  class CGParams
    def initialize
      @params = {}
    end

    def set(param, v)
      if v.is_a?(Array)
        @params[param] = v

      else
        @params[param] = [v]
      end
    end

    def [](param)
      @params[param]
    end

    def dump
      @params.map do |param, v|
        {
          'subsystem' => param.split('.').first,
          'name' => param,
          'value' => v,
        }
      end
    end
  end
end
