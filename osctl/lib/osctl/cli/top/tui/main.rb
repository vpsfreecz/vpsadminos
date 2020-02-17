require 'curses'
require 'osctl/cli/top/tui/screen'

module OsCtl::Cli::Top
  class Tui::Main < Tui::Screen
    include OsCtl::Utils::Humanize

    def initialize(model, rate)
      @model = model
      @rate = rate
      @last_measurement = nil
      @last_count = nil
      @sort_index = 0
      @sort_desc = true
      @current_row = nil
      @highlighted_cts = []
      @status_bar_cols = 0
    end

    def open
      unless last_measurement
        render(Time.now, {containers: []})
        sleep(0.5)
      end

      # At each loop pass, model is queried for data, unless `hold_data` is
      # greater than zero. In that case, `hold_data` is decremented by 1
      # on each pass.
      hold_data = 0

      loop do
        now = Time.now

        if !paused? && (last_measurement.nil? || (now - last_measurement) >= rate)
          model.measure
          self.last_measurement = now
        end

        if !last_data || hold_data == 0
          @last_data = data = get_data

        elsif hold_data > 0
          hold_data -= 1
          data = last_data
        end

        Curses.clear if last_count != data[:containers].count
        self.last_count = data[:containers].count

        render(now, data)
        Curses.timeout = rate * 1000

        case Curses.getch
        when 'q'
          return

        when Curses::Key::LEFT, '<'
          Curses.clear
          sort_next(-1)

        when Curses::Key::RIGHT, '>'
          Curses.clear
          sort_next(+1)

        when Curses::Key::UP
          selection_up
          hold_data = 1

        when Curses::Key::DOWN
          selection_down
          hold_data = 1

        when ' '
          selection_highlight

        when Curses::Key::ENTER, 10
          selection_open

        when 'r', 'R'
          Curses.clear
          sort_inverse

        when 'm'
          modes = model.class::MODES
          i = modes.index(mode)

          if i+1 >= modes.count
            model.mode = modes[0]

          else
            model.mode = modes[i+1]
          end

          @header = nil
          Curses.clear

        when 'p'
          paused? ? unpause : pause

        when '?'
          return Tui::Help.new(self)

        when Curses::Key::RESIZE
          Curses.clear
        end
      end
    end

    protected
    attr_reader :model, :rate, :highlighted_cts
    attr_accessor :last_measurement, :last_count, :last_data, :current_row

    def render(t, data)
      Curses.setpos(0, 0)
      Curses.addstr("#{File.basename($0)} ct top - #{t.strftime('%H:%M:%S')}")
      Curses.addstr(" #{model.mode} mode, load average #{loadavg}")

      i = status_bar(1, data)

      Curses.attron(Curses.color_pair(1))
      i = header(i+1)
      Curses.attroff(Curses.color_pair(1))

      data[:containers].each_with_index do |ct, j|
        Curses.setpos(i, 0)

        if current_row == j && highlighted_cts.include?(ct[:id])
          attr = Curses.color_pair(Tui::SELECTED_HIGHLIGHTED)

        elsif current_row == j
          attr = Curses.color_pair(Tui::SELECTED)

        elsif highlighted_cts.include?(ct[:id])
          attr = Curses.color_pair(Tui::HIGHLIGHTED)

        else
          attr = nil
        end

        Curses.attron(attr) if attr
        print_row(ct)
        Curses.attroff(attr) if attr

        i += 1

        break if i >= (Curses.lines - 5)
      end

      stats(data[:containers])

      Curses.refresh
    end

    def status_bar(orig_pos, data)
      pos = orig_pos
      @status_bar_cols = 0

      # CPU
      cpu = data[:cpu]

      Curses.setpos(pos, 0)
      Curses.addstr('%CPU: ')

      if cpu
        bold { Curses.addstr(sprintf('%5.1f', format_percent(cpu[:user]))) }
        Curses.addstr(' us, ')
        bold { Curses.addstr(sprintf('%5.1f', format_percent(cpu[:system]))) }
        Curses.addstr(' sy, ')
        bold { Curses.addstr(sprintf('%5.1f', format_percent(cpu[:nice]))) }
        Curses.addstr(' ni, ')
        bold { Curses.addstr(sprintf('%5.1f', format_percent(cpu[:idle]))) }
        Curses.addstr(' id, ')
        bold { Curses.addstr(sprintf('%5.1f', format_percent(cpu[:iowait]))) }
        Curses.addstr(' wa, ')
        bold { Curses.addstr(sprintf('%5.1f', format_percent(cpu[:irq]))) }
        Curses.addstr(' hi, ')
        bold { Curses.addstr(sprintf('%5.1f', format_percent(cpu[:softirq]))) }
        Curses.addstr(' si')

      else
        Curses.addstr('calculating')
      end

      # Memory
      mem = data[:memory]

      Curses.setpos(pos += 1, 0)
      Curses.addstr('Memory: ')

      if mem
        bold { Curses.addstr(sprintf('%8s', humanize_data(mem[:total]))) }
        Curses.addstr(' total, ')
        bold { Curses.addstr(sprintf('%8s', humanize_data(mem[:free]))) }
        Curses.addstr(' free, ')
        bold { Curses.addstr(sprintf('%8s', humanize_data(mem[:used]))) }
        Curses.addstr(' used, ')
        bold { Curses.addstr(sprintf('%8s', humanize_data(mem[:buffers] + mem[:cached]))) }
        Curses.addstr(' buff/cache')

        if mem[:swap_total] > 0
          Curses.setpos(pos += 1, 0)
          Curses.addstr('Swap:   ')

          bold { Curses.addstr(sprintf('%8s', humanize_data(mem[:swap_total]))) }
          Curses.addstr(' total, ')
          bold { Curses.addstr(sprintf('%8s', humanize_data(mem[:swap_free]))) }
          Curses.addstr(' free, ')
          bold { Curses.addstr(sprintf('%8s', humanize_data(mem[:swap_used]))) }
          Curses.addstr(' used')
        end

      else
        Curses.addstr('calculating')
      end

      # ZFS ARC
      arc = data[:zfs] && data[:zfs][:arc]

      Curses.setpos(pos += 1, 0)
      Curses.addstr('ARC:    ')

      if arc
        bold { Curses.addstr(sprintf('%8s', humanize_data(arc[:c_max]))) }
        Curses.addstr(' c_max, ')
        bold { Curses.addstr(sprintf('%8s', humanize_data(arc[:c]))) }
        Curses.addstr(' c,    ')
        bold { Curses.addstr(sprintf('%8s', humanize_data(arc[:size]))) }
        Curses.addstr(' size, ')
        bold { Curses.addstr(sprintf('%8.2f', format_percent(arc[:hit_rate]))) }
        Curses.addstr(' hitrate, ')
        bold { Curses.addstr(sprintf('%6d', arc[:misses])) }
        Curses.addstr(' missed ')

      else
        Curses.addstr('calculating')
      end

      l2arc = data[:zfs] && data[:zfs][:l2arc]

      if l2arc && l2arc[:size] > 0
        Curses.setpos(pos += 1, 0)
        Curses.addstr('L2ARC:  ' + ' ' * 16)

        bold { Curses.addstr(sprintf('%8s', humanize_data(l2arc[:size]))) }
        Curses.addstr(' size, ')
        bold { Curses.addstr(sprintf('%8s', humanize_data(l2arc[:asize]))) }
        Curses.addstr(' asize,')
        bold { Curses.addstr(sprintf('%8.2f', humanize_data(l2arc[:hit_rate]))) }
        Curses.addstr(' hitrate, ')
        bold { Curses.addstr(sprintf('%6d', l2arc[:misses])) }
        Curses.addstr(' missed ')
      end

      # Containers
      Curses.setpos(pos += 1, 0)
      Curses.addstr('Containers: ')
      bold { Curses.addstr(sprintf('%3d', model.containers.count)) }
      Curses.addstr(' total, ')
      bold { Curses.addstr(sprintf('%3d', model.containers.count{ |ct| ct.state == :starting })) }
      Curses.addstr(' starting, ')
      bold { Curses.addstr(sprintf('%3d', data[:containers].count-1)) } # -1 for [host]
      Curses.addstr(' running, ')
      bold { Curses.addstr(sprintf('%3d', model.containers.count{ |ct| ct.state == :stopping })) }
      Curses.addstr(' stopping, ')
      bold { Curses.addstr(sprintf('%3d', model.containers.count{ |ct| ct.state == :stopped })) }
      Curses.addstr(' stopped')

      @status_bar_cols += pos - orig_pos + 1
      pos + 1
    end

    def header(pos)
      unless @header
        ret = []

        ret << sprintf(
          '%-14s %7s %8s %6s %27s %27s',
          'Container',
          'CPU',
          'Memory',
          'Proc',
          'ZFSIO          ',
          'Network        '
        )

        ret << sprintf(
          '%-14s %7s %7s %6s %13s %13s %13s %13s',
          '',
          '',
          '',
          '',
          'Read   ',
          'Write   ',
          'TX    ',
          'RX    '
        )

        ret << sprintf(
          '%-14s %7s %7s %6s %6s %6s %6s %6s %6s %6s %6s %6s',
          'ID',
          '',
          '',
          '',
          'Bytes',
          rt? ? 'IOPS' : 'IO',
          'Bytes',
          rt? ? 'IOPS' : 'IO',
          rt? ? 'bps' : 'Bytes',
          rt? ? 'pps' : 'Packet',
          rt? ? 'bps' : 'Bytes',
          rt? ? 'pps' : 'Packet'
        )

        # Fill to the edge of the screen
        @header = ret.map do |line|
          line << (' ' * (Curses.cols - line.size)) << "\n"
        end
      end

      @header.each do |line|
        Curses.setpos(pos, 0)
        Curses.addstr(line)
        pos += 1
      end

      pos
    end

    def print_row(ct)
      Curses.addstr(sprintf('%-14s ', format_ctid(ct[:id])))

      print_row_data([
        rt? ? format_percent(ct[:cpu_usage]) : humanize_time_ns(ct[:cpu_time]),
        humanize_data(ct[:memory]),
        ct[:nproc],
        humanize_data(ct[:zfsio][:bytes][:r]),
        ct[:zfsio][:ios][:r],
        humanize_data(ct[:zfsio][:bytes][:w]),
        ct[:zfsio][:ios][:w],
        humanize_data(ct[:tx][:bytes]),
        humanize_data(ct[:tx][:packets]),
        humanize_data(ct[:rx][:bytes]),
        humanize_data(ct[:rx][:packets])
      ])
    end

    def print_row_data(values)
      fmts = %w(%7s %8s %6s %6s %6s %6s %6s %6s %6s %6s %6s)
      w = 15 # container ID is printed in {#print_row}

      fmts.zip(values).each_with_index do |pair, i|
        f, v = pair
        s = sprintf("#{f} ", v)
        w += s.length

        Curses.attron(Curses::A_BOLD) if i == @sort_index
        Curses.addstr(s)
        Curses.attroff(Curses::A_BOLD) if i == @sort_index
      end

      # Fill space to the edge of the screen, needed for selected rows
      Curses.addstr(' ' * (Curses.cols - w)) if Curses.cols > w
    end

    def stats(cts)
      Curses.setpos(Curses.lines - 5, 0)
      Curses.addstr('─' * Curses.cols)
      #Curses.addstr('-' * Curses.cols)

      Curses.setpos(Curses.lines - 4, 0)
      Curses.addstr(sprintf('%-14s ', 'Containers:'))
      print_row_data([
        rt? ? format_percent(sum(cts, :cpu_usage, false)) \
            : humanize_time_ns(sum(cts, :cpu_time, false)),
        humanize_data(sum(cts, :memory, false)),
        sum(cts, :nproc, false),
        humanize_data(sum(cts, [:zfsio, :bytes, :r], false)),
        sum(cts, [:zfsio, :ios, :r], false),
        humanize_data(sum(cts, [:zfsio, :bytes, :w], false)),
        sum(cts, [:zfsio, :ios, :w], false),
        humanize_data(sum(cts, [:tx, :bytes], false)),
        humanize_data(sum(cts, [:tx, :packets], false)),
        humanize_data(sum(cts, [:rx, :bytes], false)),
        humanize_data(sum(cts, [:rx, :packets], false))
      ])

      Curses.setpos(Curses.lines - 3, 0)
      Curses.addstr(sprintf('%-14s ', 'All:'))
      print_row_data([
        rt? ? format_percent(sum(cts, :cpu_usage, true)) \
            : humanize_time_ns(sum(cts, :cpu_time, true)),
        humanize_data(sum(cts, :memory, true)),
        sum(cts, :nproc, true),
        humanize_data(sum(cts, [:zfsio, :bytes, :r], true)),
        sum(cts, [:zfsio, :ios, :r], true),
        humanize_data(sum(cts, [:zfsio, :bytes, :w], true)),
        sum(cts, [:zfsio, :ios, :w], true),
        humanize_data(sum(cts, [:tx, :bytes], true)),
        humanize_data(sum(cts, [:tx, :packets], true)),
        humanize_data(sum(cts, [:rx, :bytes], true)),
        humanize_data(sum(cts, [:rx, :packets], true))
      ])

      Curses.setpos(Curses.lines - 2, 0)
      Curses.addstr('─' * Curses.cols)
      Curses.setpos(Curses.lines - 1, 0)
      fillRow do
        Curses.addstr('Selected container: ')

        if @current_row && (ct = last_data[:containers][@current_row])
          if ct[:id] == '[host]'
            Curses.addstr('host system')
          else
            Curses.addstr("#{ct[:pool]}:#{ct[:id]}")
          end
        else
          Curses.addstr('none')
        end
      end
    end

    def get_data
      ret = model.data

      ret[:containers].sort! do |a, b|
        sortable_value(a) <=> sortable_value(b)
      end

      ret[:containers].reverse! if @sort_desc
      ret
    end

    def sortable_value(ct)
      lookup_field(ct, sortable_fields[@sort_index])
    end

    def sort_next(n)
      next_i = @sort_index + n
      fields = sortable_fields

      if next_i < 0
        next_i = fields.count - 1

      elsif next_i >= fields.count
        next_i = 0
      end

      @sort_index = next_i
    end

    def sort_inverse
      @sort_desc = !@sort_desc
    end

    def sortable_fields
      ret = []
      ret << (rt? ? :cpu_usage : :cpu_time)
      ret.concat([
        :memory,
        :nproc,
        [:zfsio, :bytes, :r],
        [:zfsio, :ios, :r],
        [:zfsio, :bytes, :w],
        [:zfsio, :ios, :w],
        [:tx, :bytes],
        [:tx, :packets],
        [:rx, :bytes],
        [:rx, :packets],
      ])
    end

    def selection_up
      last_row = [max_rows - 1, last_data[:containers].size - 1].min

      if @current_row
        new_row = @current_row - 1

        if new_row >= 0
          @current_row = new_row

        elsif new_row == -1
          @current_row = nil

        elsif last_data[:containers].any?
          @current_row = last_row

        else
          @current_row = nil
        end

      elsif last_data[:containers].any?
        @current_row = last_row
      end
    end

    def selection_down
      if @current_row
        new_row = @current_row + 1

        if new_row < last_data[:containers].size && new_row < max_rows
          @current_row = new_row

        elsif last_data[:containers].any?
          @current_row = 0

        else
          @current_row = nil
        end

      elsif last_data[:containers].any?
        @current_row = 0
      end
    end

    def selection_highlight
      return unless @current_row

      ct = last_data[:containers][@current_row]
      return unless ct

      ctid = ct[:id]

      if highlighted_cts.include?(ctid)
        highlighted_cts.delete(ctid)

      else
        highlighted_cts << ctid
      end
    end

    def selection_open
      return unless @current_row

      ct = last_data[:containers][@current_row]
      return unless ct

      if ct[:id] == '[host]'
        ctid = 'host'

      else
        ctid = "#{ct[:pool]}:#{ct[:id]}"
      end

      pid = Process.fork do
        Process.exec('htop', '-c', ctid)
      end

      Process.wait(pid)

      # The screen needs to be reinitialized after htop
      Curses.init_screen
      Curses.start_color
      Curses.crmode
      Curses.stdscr.keypad = true
      Curses.curs_set(0)  # hide cursor
      Curses.clear
    end

    def sum(cts, field, host)
      cts.inject(0) do |acc, ct|
        if ct[:id] == '[host]' && !host
          acc

        else
          acc + lookup_field(ct, field)
        end
      end
    end

    def lookup_field(ct, field)
      if field.is_a?(Array)
        field.reduce(ct) { |acc, v| acc[v] }

      else
        ct[field]
      end
    end

    def loadavg
      File.read('/proc/loadavg').strip.split(' ')[0..2].join(', ')
    end

    def mode
      model.mode
    end

    def rt?
      model.mode == :realtime
    end

    def format_ctid(ctid)
      if ctid.length > 12
        ctid[0..11] + '..'
      else
        ctid
      end
    end

    def bold
      Curses.attron(Curses::A_BOLD)
      yield
      Curses.attroff(Curses::A_BOLD)
    end

    def fillRow
      yield
      x, y = cursor
      Curses.addstr(' ' * (Curses.cols - x))
    end

    def cursor
      res = ''

      $stdin.raw do |stdin|
        $stdout << "\e[6n"
        $stdout.flush
        while (c = stdin.getc) != 'R'
          res << c if c
        end
      end

      m = res.match /(?<row>\d+);(?<column>\d+)/
      [m[:column].to_i, m[:row].to_i]
    end

    # Screen without header and footer
    def max_rows
      Curses.lines - @status_bar_cols - 1 - @header.size - 5 - 1
    end

    def pause
      @paused = true
    end

    def unpause
      @paused = false
    end

    def paused?
      @paused
    end
  end
end
