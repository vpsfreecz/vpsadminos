module OsCtld
  class Eventd::Event
    attr_reader :type, :opts

    def initialize(type, opts)
      @type = type
      @opts = opts
    end
  end
end
