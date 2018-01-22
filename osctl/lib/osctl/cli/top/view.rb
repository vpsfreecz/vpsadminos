module OsCtl::Cli
  class Top::View
    attr_reader :model, :rate

    def initialize(model, rate)
      @model = model
      @rate = rate
    end

    def start
      raise NotImplementedError
    end
  end
end
