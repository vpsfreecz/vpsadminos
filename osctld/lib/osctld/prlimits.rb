module OsCtld
  module PrLimits
    # @param resource [String]
    # @return [Integer]
    def self.resource_to_const(resource)
      PrLimits.const_get(resource.upcase)
    end
  end
end
