module OsCtl::Lib
  # Container for values that should be treated and presented differently
  #
  # {Cli::Presentable} is used for {Cli::OutputFormatter}, so that values
  # are sorted by their precise representation, but presented as a formatted
  # string, whose sorting would yield incorrect results.
  #
  # The formatting is done either by passing a `presenter` callable, or
  # the `formatted` value. If `presenter` is given, it is called to format
  # the value, otherwise `formatted` is used.
  class Cli::Presentable
    # Return the raw, precise value
    attr_reader :raw

    # Return the formatted value for presentation
    attr_reader :formatted

    # @param raw [any] precise value
    # @param presenter [Method, Proc] called to format the value
    # @param formatted [String] formatted value
    def initialize(raw, presenter: nil, formatted: nil)
      @raw = raw

      v = presenter ? presenter.call(raw) : formatted
      @formatted = v ? v.to_s : raw.to_s
    end

    %i(- + * / <= == >= <=>).each do |m|
      define_method(m) do |other|
        if other.is_a?(self.class)
          raw.send(m, other.raw)
        else
          raw.send(m, other)
        end
      end
    end

    def coerce(other)
      [other, raw]
    end

    # Returns the formatted value
    def to_s
      formatted
    end

    # Returns the raw value in JSON
    def to_json(*args)
      raw.to_json(*args)
    end
  end
end
