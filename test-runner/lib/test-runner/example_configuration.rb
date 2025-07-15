module TestRunner
  class ExampleConfiguration
    # @return [:defined, :rand, Random, Integer]
    attr_accessor :default_order

    def initialize
      @default_order = :rand
    end
  end
end
