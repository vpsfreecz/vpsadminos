module OsCtl
  module Utils::Humanize
    def humanize_data(v)
      bits = 39
      units = %i(T G M K)

      units.each do |u|
        threshold = 2 << bits

        return "#{(v / threshold.to_f).round(1)}#{u}" if v >= threshold

        bits -= 10
      end

      v.round(2).to_s
    end

    def humanize_number(v)
      divider = 10.0 ** 12
      units = %i(T G M K)

      units.each do |u|
        division = v / divider
        return "#{division.round(1)}#{u}" if division >= 1

        divider /= 1000
      end

      v.round(2).to_s
    end

    def humanize_time_ns(v)
      format_short_duration(v / 1_000_000_000)
    end

    def format_long_duration(interval)
      d, h, m, s = break_interval(interval)

      if d > 0
        "%d days, %02d:%02d:%02d" % [d, h, m, s]
      else
        "%02d:%02d:%02d" % [h, m, s]
      end
    end

    def format_short_duration(interval)
      d, h, m, s = break_interval(interval)

      if d == 0 && h == 0 && m == 0
        "#{s}s"

      elsif d == 0 && h == 0
        '%02d:%02d' % [m, s]

      elsif d == 0
        '%02d:%02d:%02d' % [h, m, s]

      else
        '%dd, %02d:%02d:%02d' % [d, h, m, s]
      end
    end

    def format_percent(v)
      v.round(1)
    end

    def parse_data(v)
      units = %w(k m g t)

      if /^\d+$/ =~ v
        v.to_i

      elsif /^(\d+)(#{units.join('|')})$/i =~ v
        n = $1.to_i
        i = units.index($2.downcase)

        n * (2 << (9 + (10*i)))

      else
        v
      end
    end

    protected
    def break_interval(interval)
      d = interval / 86400
      h = interval / 3600 % 24
      m = interval / 60 % 60
      s = interval % 60
      [d, h, m, s]
    end
  end
end
