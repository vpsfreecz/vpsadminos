require 'rainbow'

module OsCtl::Lib::Cli
  # Format and print data in column or row view
  class OutputFormatter
    # Format data and return as string
    # @return [String]
    def self.format(*, **)
      f = new(*, **)
      f.format
    end

    # Format data and print to standard output
    def self.print(*, **)
      f = new(*, **)
      f.print
    end

    # @param objects [Hash, Array]
    # @param cols [Array<Symbol, Hash>, nil] a list of parameter names to show
    # @param opts [Hash<Symbol, Hash>] column options
    # @param header [Boolean] whether to show header
    # @param sort [Array<Symbol>, nil] array of parameter names to sort by
    # @param layout [:columns, :rows]
    # @param empty [String] string used for nil values
    # @param color [Boolean] handle color escape sequences in formatted strings
    def initialize(objects, cols: nil, opts: {}, header: true, sort: nil, layout: nil, empty: '-', color: false)
      @objects = objects
      @opts = opts
      @header = header
      @sort = sort
      @layout = layout
      @empty = empty
      @color = color

      if @layout.nil?
        @layout = if many?
                    :columns

                  else
                    :rows
                  end
      end

      if cols
        @cols = parse_cols(cols)

      elsif @objects.is_a?(::Array) # A list of items
        if @objects.count == 0
          @cols = []
        else
          @cols ||= parse_cols(@objects.first.keys)
        end

      elsif @objects.is_a?(::Hash) # Single item
        @cols ||= parse_cols(@objects.keys)

      else
        raise "unsupported type #{@objects.class}"
      end
    end

    # @return [String]
    def format
      @out = ''
      generate
      @out
    end

    def print
      @out = nil
      generate
    end

    protected

    def parse_cols(cols)
      ret = []

      cols.each do |c|
        base = {
          align: 'left'
        }

        if c.is_a?(::String) || c.is_a?(::Symbol)
          base.update({
            name: c,
            label: c.to_s.upcase
          })
          base.update(@opts.fetch(c, {}))
          ret << base

        elsif c.is_a?(::Hash)
          base.update(c)
          base.update(@opts.fetch(c[:name], {}))
          ret << base

        else
          raise "unsupported column type #{c.class}"
        end
      end

      ret
    end

    def generate
      return if @cols.empty?

      prepare

      case @layout
      when :columns
        columns

      when :rows
        rows

      else
        raise "unsupported layout '#{@layout}'"
      end
    end

    # Each object is printed on one line, it's parameters aligned into columns.
    def columns
      # Calculate column widths
      @cols.each_with_index do |c, i|
        c[:width] = col_width(i, c)
      end

      # Print header
      if @header
        line(@cols.map.with_index do |c, i|
          fmt =
            if i == (@cols.count - 1)
              '%s'
            elsif c[:align].to_sym == :right
              "%#{c[:width]}s"
            else
              "%-#{c[:width]}s"
            end

          format(fmt, c[:label])
        end.join('  '))
      end

      # Print data
      @str_objects.each do |o|
        line(@cols.map.with_index do |c, i|
          s = o[i].to_s

          if @color
            # If there are colors in the string, they affect the string size
            # and thus sprintf formatting. sprintf is working with characters
            # that the terminal will consume and not display (escape sequences).
            # The format string needs to be changed to accomodate for those
            # unprintable characters.
            s_nocolor = Rainbow::StringUtils.uncolor(s)

            w = if s_nocolor.length == s.length
                  c[:width]

                else
                  c[:width] + (s.length - s_nocolor.length)
                end
          else
            w = c[:width]
          end

          fmt =
            if i == (@cols.count - 1)
              '%s'
            elsif c[:align].to_sym == :right
              "%#{w}s"
            else
              "%-#{w}s"
            end

          format(fmt, s)
        end.join('  '))
      end
    end

    # Each object is printed on multiple lines, one parameter per line.
    def rows
      w = heading_width if @header

      @str_objects.each do |o|
        @cols.each_index do |i|
          c = @cols[i]

          unless @header
            line o[i]
            next
          end

          if o[i].is_a?(::String) && o[i].index("\n")
            lines = o[i].split("\n")
            v = ([lines.first] + lines[1..].map { |l| (' ' * (w + 3)) + l }).join("\n")

          else
            v = o[i]
          end

          # rubocop:disable Lint/FormatParameterMismatch
          line format("%#{w}s:  %s", c[:label], v)
          # rubocop:enable Lint/FormatParameterMismatch
        end

        line
      end
    end

    def line(str = '')
      if @out
        @out += "#{str}\n"

      else
        puts str
      end
    end

    def prepare
      @str_objects = []

      each_object do |o|
        arr = []

        @cols.each do |c|
          v = o[c[:name]]
          str = (c[:display] ? c[:display].call(v, o) : v)
          str = @empty if !str || (str.is_a?(::String) && str.empty?)

          arr << str
        end

        @str_objects << arr
      end

      if @sort
        col_indexes = @sort.map do |s|
          i = @cols.index { |c| c[:name] == s }
          raise "unknown sort column '#{s}'" unless i

          i
        end

        @str_objects.sort! do |a, b|
          a_vals = col_indexes.map { |i| a[i] }
          b_vals = col_indexes.map { |i| b[i] }
          cmp = a_vals <=> b_vals
          next(cmp) if cmp

          next(-1) if [nil, @empty].detect { |v| a_vals.include?(v) }
          next(1) if [nil, @empty].detect { |v| b_vals.include?(v) }

          0
        end
      end

      @str_objects
    end

    def col_width(i, c)
      w = c[:label].to_s.length

      @str_objects.each do |o|
        len = if @color
                Rainbow::StringUtils.uncolor(o[i].to_s).length
              else
                o[i].to_s.length
              end

        w = len if len > w
      end

      w + 1
    end

    def heading_width
      w = @cols.first[:label].to_s.length

      @cols.each do |c|
        len = c[:label].to_s.length

        w = len if len > w
      end

      w + 1
    end

    def each_object(&)
      if @objects.is_a?(::Array)
        @objects.each(&)

      else
        yield(@objects)
      end
    end

    def many?
      @objects.is_a?(::Array) && @objects.size > 1
    end
  end
end
