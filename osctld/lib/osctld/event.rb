module OsCtld
  class Event
    attr_reader :type, :opts

    def initialize(type, opts)
      @type = type
      @opts = opts
    end
  end
end
