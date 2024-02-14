require 'curses'
require 'libosctl'
require 'osctl/cli/top/tui/screen'

module OsCtl::Cli::Top
  class Tui::Main < Tui::Screen
    include OsCtl::Lib::Utils::Humanize

    def initialize(model, rate, enable_procs: true)
      super()
      @rate = rate
      @last_count = nil
      @sort_index = 0
      @sort_desc = true
      @current_row = nil
      @view_page = 0
      @search_string = ''
      @highlighted_cts = []
      @status_bar_cols = 0
      @model_thread = Tui::ModelThread.new(model, rate)
      @model_thread.start
      @enable_procs = enable_procs
      if enable_procs
        @procs_thread = Tui::ProcessThread.new(rate)
        @procs_thread.start
      end
      @last_measurement = nil
      @last_generation = -1
      @last_procs_check = nil
      @last_mode = model_thread.mode
    end

    def open
      empty_data = { containers: [] }
      data = { containers: [] }
      procs_stats, @last_procs_check = enable_procs && procs_thread.get_stats

      # Initial render
      render(Time.now, procs_stats, empty_data) if last_generation == -1

      # At each loop pass, model is queried for data, unless `hold_data` is
      # greater than zero. In that case, `hold_data` is decremented by 1
      # on each pass.
      hold_data = 0

      loop do
        now = Time.now

        if last_generation != model_thread.generation \
           && (!last_data || hold_data == 0) \
           && !paused?
          data = get_data

        elsif hold_data > 0
          hold_data -= 1
          data = last_data
        end

        if last_mode != model_thread.mode
          @header = nil
          Curses.clear
          @last_mode = model_thread.mode
        elsif last_count != data[:containers].count
          Curses.clear
        end

        self.last_count = data[:containers].count

        if enable_procs && !paused?
          procs_stats, @last_procs_check = procs_thread.get_stats
        end

        render(now, procs_stats, data)
        Curses.timeout = rate * 1000
        input = Curses.getch

        if search_in_focus?
          case input
          when Curses::Key::ENTER, Tui::Key::ENTER
            search_end_focus
          when Tui::Key::ESCAPE
            search_cancel
          when Curses::Key::BACKSPACE, Tui::Key::BACKSPACE
            search_chop
          else
            if input && input.is_a?(String)
              search_add(input)
              Curses.clear
            end
          end

          next
        end

        case input
        when 'q'
          procs_thread.stop if enable_procs
          model_thread.stop
          return

        when Curses::Key::LEFT, '<'
          Curses.clear
          sort_next(-1)
          run_sort

        when Curses::Key::RIGHT, '>'
          Curses.clear
          sort_next(+1)
          run_sort

        when Curses::Key::UP
          selection_up
          hold_data = 1

        when Curses::Key::DOWN
          selection_down
          hold_data = 1

        when ' '
          selection_highlight

        when Curses::Key::ENTER, Tui::Key::ENTER, 't'
          selection_open_top

        when Curses::Key::NPAGE # Page Down
          view_page_down

        when Curses::Key::PPAGE # Page Up
          view_page_up

        when Curses::Key::HOME
          view_page_reset

        when Curses::Key::END
          view_page_end

        when 'h'
          selection_open_htop

        when 'r', 'R'
          Curses.clear
          sort_inverse
          run_sort

        when 'm'
          modes = Model::MODES
          i = modes.index(mode)

          model_thread.mode = if i + 1 >= modes.count
                                modes[0]

                              else
                                modes[i + 1]
                              end

        when 'p'
          paused? ? unpause : pause

        when '/'
          search_start_focus

        when '?'
          return Tui::Help.new(self)

        when Curses::Key::RESIZE
          Curses.clear
        end
      end
    end

    protected

    attr_reader :rate, :model_thread, :procs_thread, :highlighted_cts, :last_measurement, :last_generation, :last_procs_check, :last_mode, :view_page, :view_page_max, :enable_procs, :search_string
    attr_accessor :last_count, :last_data, :current_row

    def render(t, procs_stats, data)
      Curses.setpos(0, 0)
      Curses.addstr("#{File.basename($0)} ct top - #{t.strftime('%H:%M:%S')}")
      Curses.addstr(format(' [%.1fs]', last_measurement - t)) if last_measurement

      lavg = data[:loadavg] ? format_loadavgs(data[:loadavg]) : '?'
      Curses.addstr(" #{model_thread.mode} mode, load average #{lavg}")

      i = status_bar(1, t, procs_stats, data)

      Curses.attron(Curses.color_pair(1))
      i = header(i + 1)
      j = 0
      Curses.attroff(Curses.color_pair(1))

      ct_count = data[:containers].length
      offset = 0
      view_ct_count = Curses.lines - stats_rows - i

      @view_page_max = ((ct_count - view_ct_count) / (view_ct_count / 2).to_f).ceil

      ct_view =
        if view_page > 0
          offset = (view_ct_count / 2) * view_page

          if offset >= ct_count - view_ct_count
            offset = ct_count - view_ct_count
          end

          data[:containers][offset..]
        else
          data[:containers]
        end

      ct_view.each do |ct|
        next if search_active? && !ct[:id].include?(search_string)

        Curses.setpos(i, 0)

        attr = if current_row == j && highlighted_cts.include?(ct[:id])
                 Curses.color_pair(Tui::SELECTED_HIGHLIGHTED)

               elsif current_row == j
                 Curses.color_pair(Tui::SELECTED)

               elsif highlighted_cts.include?(ct[:id])
                 Curses.color_pair(Tui::HIGHLIGHTED)

               end

        Curses.attron(attr) if attr
        print_row(ct)
        Curses.attroff(attr) if attr

        i += 1
        j += 1

        break if i >= (Curses.lines - stats_rows)
      end

      stats(data, [offset, view_ct_count, data[:containers].length])

      Curses.refresh
    end

    def status_bar(orig_pos, t, procs_stats, data)
      pos = orig_pos
      @status_bar_cols = 0

      # Processes
      if enable_procs
        Curses.setpos(pos, 0)
        Curses.addstr('Tasks')
        Curses.addstr(format(' [%.1fs]', @last_procs_check - t)) if @last_procs_check
        Curses.addstr(': ')
        bold { Curses.addstr(format('%5d', procs_stats['TOTAL'])) }
        Curses.addstr(' total, ')
        bold { Curses.addstr(format('%3d', procs_stats['R'])) }
        Curses.addstr(' running, ')
        bold { Curses.addstr(format('%3d', procs_stats['D'])) }
        Curses.addstr(' blocked, ')
        bold { Curses.addstr(format('%5d', procs_stats['S'])) }
        Curses.addstr(' sleeping, ')
        bold { Curses.addstr(format('%2d', procs_stats['T'])) }
        Curses.addstr(' stopped, ')
        bold { Curses.addstr(format('%2d', procs_stats['Z'])) }
        Curses.addstr(' zombie ')
        pos += 1
      end

      # CPU
      cpu = data[:cpu]

      Curses.setpos(pos, 0)
      Curses.addstr('%CPU: ')

      if cpu
        bold { Curses.addstr(format('%5.1f', format_percent(cpu[:user]))) }
        Curses.addstr(' us, ')
        bold { Curses.addstr(format('%5.1f', format_percent(cpu[:system]))) }
        Curses.addstr(' sy, ')
        bold { Curses.addstr(format('%5.1f', format_percent(cpu[:nice]))) }
        Curses.addstr(' ni, ')
        bold { Curses.addstr(format('%5.1f', format_percent(cpu[:idle]))) }
        Curses.addstr(' id, ')
        bold { Curses.addstr(format('%5.1f', format_percent(cpu[:iowait]))) }
        Curses.addstr(' wa, ')
        bold { Curses.addstr(format('%5.1f', format_percent(cpu[:irq]))) }
        Curses.addstr(' hi, ')
        bold { Curses.addstr(format('%5.1f', format_percent(cpu[:softirq]))) }
        Curses.addstr(' si')

      else
        Curses.addstr('calculating')
      end

      # Memory
      mem = data[:memory]

      Curses.setpos(pos += 1, 0)
      Curses.addstr('Memory: ')

      if mem
        bold { Curses.addstr(format('%8s', humanize_data(mem[:total]))) }
        Curses.addstr(' total, ')
        bold { Curses.addstr(format('%8s', humanize_data(mem[:free]))) }
        Curses.addstr(' free, ')
        bold { Curses.addstr(format('%8s', humanize_data(mem[:used]))) }
        Curses.addstr(' used, ')
        bold { Curses.addstr(format('%8s', humanize_data(mem[:buffers] + mem[:cached]))) }
        Curses.addstr(' buff/cache')

        if mem[:swap_total] > 0
          Curses.setpos(pos += 1, 0)
          Curses.addstr('Swap:   ')

          bold { Curses.addstr(format('%8s', humanize_data(mem[:swap_total]))) }
          Curses.addstr(' total, ')
          bold { Curses.addstr(format('%8s', humanize_data(mem[:swap_free]))) }
          Curses.addstr(' free, ')
          bold { Curses.addstr(format('%8s', humanize_data(mem[:swap_used]))) }
          Curses.addstr(' used')
        end

      else
        Curses.addstr('calculating')
      end

      # ZFS ARC
      arc = data[:zfs] && data[:zfs][:arcstats][:arc]

      Curses.setpos(pos += 1, 0)
      Curses.addstr('ARC:    ')

      if arc
        bold { Curses.addstr(format('%8s', humanize_data(arc[:c_max]))) }
        Curses.addstr(' c_max, ')
        bold { Curses.addstr(format('%8s', humanize_data(arc[:c]))) }
        Curses.addstr(' c,    ')
        bold { Curses.addstr(format('%8s', humanize_data(arc[:size]))) }
        Curses.addstr(' size, ')
        bold { Curses.addstr(format('%8.2f', format_percent(arc[:hit_rate]))) }
        Curses.addstr(' hitrate, ')
        bold { Curses.addstr(format('%6d', arc[:misses])) }
        Curses.addstr(' missed ')

      else
        Curses.addstr('calculating')
      end

      l2arc = data[:zfs] && data[:zfs][:arcstats][:l2arc]

      if l2arc && l2arc[:size] > 0
        Curses.setpos(pos += 1, 0)
        Curses.addstr("L2ARC:  #{' ' * 16}")

        bold { Curses.addstr(format('%8s', humanize_data(l2arc[:size]))) }
        Curses.addstr(' size, ')
        bold { Curses.addstr(format('%8s', humanize_data(l2arc[:asize]))) }
        Curses.addstr(' asize,')
        bold { Curses.addstr(format('%8.2f', humanize_data(l2arc[:hit_rate]))) }
        Curses.addstr(' hitrate, ')
        bold { Curses.addstr(format('%6d', l2arc[:misses])) }
        Curses.addstr(' missed ')
      end

      # Containers
      Curses.setpos(pos += 1, 0)
      Curses.addstr('Containers: ')
      bold { Curses.addstr(format('%3d', model_thread.containers.count)) }
      Curses.addstr(' total, ')
      bold { Curses.addstr(format('%3d', model_thread.containers.count { |ct| ct.state == :starting })) }
      Curses.addstr(' starting, ')
      bold { Curses.addstr(format('%3d', data[:containers].count - 1)) } # -1 for [host]
      Curses.addstr(' running, ')
      bold { Curses.addstr(format('%3d', model_thread.containers.count { |ct| ct.state == :stopping })) }
      Curses.addstr(' stopping, ')
      bold { Curses.addstr(format('%3d', model_thread.containers.count { |ct| ct.state == :stopped })) }
      Curses.addstr(' stopped')

      @status_bar_cols += pos - orig_pos + 1
      pos + 1
    end

    def header(pos)
      unless @header
        ret = []

        ret << format(
          '%-14s %9s %8s %6s %27s %27s %17s',
          'Container',
          'CPU',
          'Memory',
          'Proc',
          'ZFSIO          ',
          'Network        ',
          'LoadAvg    '
        )

        ret << format(
          '%-14s %9s %7s %8s %13s %13s %13s %13s',
          '',
          '',
          '',
          '',
          'Read   ',
          'Write   ',
          'TX    ',
          'RX    '
        )

        ret << format(
          '%-14s %9s %8s %6s %6s %6s %6s %6s %6s %6s %6s %6s %5s %5s %5s',
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
          rt? ? 'pps' : 'Packet',
          '1m', '5m', '15m'
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
      Curses.addstr(format('%-14s ', format_ctid(ct[:id])))

      cpu = (rt? ? format_percent(ct[:cpu_usage]) : humanize_time_us(ct[:cpu_us])).to_s
      cpu << "/#{ct[:cpu_package_inuse]}" if ct[:cpu_package_inuse]

      print_row_data([
                       cpu,
                       humanize_data(ct[:memory]),
                       ct[:nproc],
                       humanize_data(ct[:zfsio][:bytes][:r]),
                       humanize_number(ct[:zfsio][:ios][:r]),
                       humanize_data(ct[:zfsio][:bytes][:w]),
                       humanize_number(ct[:zfsio][:ios][:w]),
                       humanize_data(rt? ? ct[:tx][:bytes] * 8 : ct[:tx][:bytes]),
                       humanize_data(ct[:tx][:packets]),
                       humanize_data(rt? ? ct[:rx][:bytes] * 8 : ct[:rx][:bytes]),
                       humanize_data(ct[:rx][:packets]),
                       format_loadavg(ct[:loadavg][0]),
                       format_loadavg(ct[:loadavg][1]),
                       format_loadavg(ct[:loadavg][2])
                     ])
    end

    def print_row_data(values)
      fmts = %w[%9s %8s %6s %6s %6s %6s %6s %6s %6s %6s %6s %5s %5s %5s]
      w = 15 # container ID is printed in {#print_row}

      fmts.zip(values).each_with_index do |pair, i|
        f, v = pair
        s = format("#{f} ", v)
        w += s.length

        Curses.attron(Curses::A_BOLD) if i == @sort_index
        Curses.addstr(s)
        Curses.attroff(Curses::A_BOLD) if i == @sort_index
      end

      # Fill space to the edge of the screen, needed for selected rows
      Curses.addstr(' ' * (Curses.cols - w)) if Curses.cols > w
    end

    def stats_rows
      i = 5
      i += 1 if model_thread.iostat_enabled?
      i
    end

    def stats(data, ct_view)
      cts = data[:containers]
      pos = stats_rows

      Curses.setpos(Curses.lines - pos, 0)
      pos -= 1
      Curses.addstr('─' * Curses.cols)
      # Curses.addstr('-' * Curses.cols)

      Curses.setpos(Curses.lines - pos, 0)
      pos -= 1
      Curses.addstr(format('%-14s ', 'Containers:'))
      print_row_data([
                       if rt?
                         format_percent(sum(cts, :cpu_usage, false))
                       else
                         humanize_time_us(sum(cts, :cpu_us, false))
                       end,
                       humanize_data(sum(cts, :memory, false)),
                       sum(cts, :nproc, false),
                       humanize_data(sum(cts, %i[zfsio bytes r], false)),
                       humanize_number(sum(cts, %i[zfsio ios r], false)),
                       humanize_data(sum(cts, %i[zfsio bytes w], false)),
                       humanize_number(sum(cts, %i[zfsio ios w], false)),
                       humanize_data(sum(cts, %i[tx bytes], false) * (rt? ? 8 : 1)),
                       humanize_data(sum(cts, %i[tx packets], false)),
                       humanize_data(sum(cts, %i[rx bytes], false) * (rt? ? 8 : 1)),
                       humanize_data(sum(cts, %i[rx packets], false)),
                       format_loadavg(sum(cts, [:loadavg, 0], false)),
                       format_loadavg(sum(cts, [:loadavg, 1], false)),
                       format_loadavg(sum(cts, [:loadavg, 2], false))
                     ])

      Curses.setpos(Curses.lines - pos, 0)
      pos -= 1
      Curses.addstr(format('%-14s ', 'All:'))
      print_row_data([
                       if rt?
                         format_percent(sum(cts, :cpu_usage, true))
                       else
                         humanize_time_us(sum(cts, :cpu_us, true))
                       end,
                       humanize_data(sum(cts, :memory, true)),
                       sum(cts, :nproc, true),
                       humanize_data(sum(cts, %i[zfsio bytes r], true)),
                       humanize_number(sum(cts, %i[zfsio ios r], true)),
                       humanize_data(sum(cts, %i[zfsio bytes w], true)),
                       humanize_number(sum(cts, %i[zfsio ios w], true)),
                       humanize_data(sum(cts, %i[tx bytes], true) * (rt? ? 8 : 1)),
                       humanize_data(sum(cts, %i[tx packets], true)),
                       humanize_data(sum(cts, %i[rx bytes], true) * (rt? ? 8 : 1)),
                       humanize_data(sum(cts, %i[rx packets], true)),
                       data[:loadavg] ? format_loadavg(data[:loadavg][0]) : '-',
                       data[:loadavg] ? format_loadavg(data[:loadavg][1]) : '-',
                       data[:loadavg] ? format_loadavg(data[:loadavg][2]) : '-'
                     ])

      if model_thread.iostat_enabled?
        iostat = data[:zfs] && data[:zfs][:iostat]

        Curses.setpos(Curses.lines - pos, 0)
        pos -= 1
        Curses.addstr(format('%-14s ', 'iostat:'))

        if iostat
          print_row_data([
                           '-',
                           '-',
                           '-',
                           humanize_data(iostat[:bytes_read]),
                           humanize_data(iostat[:io_read]),
                           humanize_data(iostat[:bytes_written]),
                           humanize_data(iostat[:io_written]),
                           '-',
                           '-',
                           '-',
                           '-',
                           '-',
                           '-',
                           '-'
                         ])
        end
      end

      Curses.setpos(Curses.lines - pos, 0)
      pos -= 1
      Curses.addstr('─' * Curses.cols)
      Curses.setpos(Curses.lines - pos, 0)

      search_msg = nil

      fill_row do
        if search_in_focus? || search_active?
          search_msg = "Search: #{search_string}"
          Curses.addstr(search_msg)
          next
        end

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

      offset, view_count, ct_count = ct_view
      page = format('[%d-%d/%d]', offset + 1, offset + view_count, ct_count)

      Curses.setpos(Curses.lines - pos, Curses.cols - page.length)
      Curses.addstr(page)

      return unless search_in_focus?

      Curses.setpos(Curses.lines - pos, search_msg.length)
    end

    def get_data
      ret, measured_at, generation = model_thread.get_data

      @last_data = ret
      @last_measurement = measured_at
      @last_generation = generation

      run_sort
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
      ret << (rt? ? :cpu_usage : :cpu_us)
      ret.push(
        :memory,
        :nproc,
        %i[zfsio bytes r],
        %i[zfsio ios r],
        %i[zfsio bytes w],
        %i[zfsio ios w],
        %i[tx bytes],
        %i[tx packets],
        %i[rx bytes],
        %i[rx packets],
        [:loadavg, 0],
        [:loadavg, 1],
        [:loadavg, 2]
      )
    end

    def run_sort
      last_data[:containers].sort! do |a, b|
        sortable_value(a) <=> sortable_value(b)
      end

      last_data[:containers].reverse! if @sort_desc
    end

    def selection_up
      last_row = [max_rows - 1, last_data[:containers].size - 1].min

      if @current_row
        new_row = @current_row - 1

        @current_row = if new_row >= 0
                         new_row

                       elsif new_row == -1
                         nil

                       elsif last_data[:containers].any?
                         last_row

                       end

      elsif last_data[:containers].any?
        @current_row = last_row
      end
    end

    def selection_down
      if @current_row
        new_row = @current_row + 1

        @current_row = if new_row < last_data[:containers].size && new_row < max_rows
                         new_row

                       elsif last_data[:containers].any?
                         0

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

    def selection_open_top
      selection_open_program { %w[top] }
    end

    def selection_open_htop
      selection_open_program { %w[htop] }
    end

    def selection_open_program(&block)
      return unless @current_row

      ct = last_data[:containers][@current_row]
      return unless ct

      if ct[:id] == '[host]'
        pid = Process.fork do
          Curses.close_screen
          Process.exec(*block.call)
        end
      elsif ct[:init_pid]
        pid = Process.fork do
          sys = OsCtl::Lib::Sys.new

          sys.setns_path(
            File.join('/proc', ct[:init_pid].to_s, 'ns/pid'),
            OsCtl::Lib::Sys::CLONE_NEWPID
          )
          sys.unshare_ns(OsCtl::Lib::Sys::CLONE_NEWNS)

          # Enter the PID namespace in a child process
          child = Process.fork do
            sys.mount_proc('/proc')

            Curses.close_screen
            Process.exec(*block.call)
          end

          Process.wait(child)
          exit($?.exitstatus)
        end
      else
        return
      end

      Process.wait(pid)

      # The screen needs to be reinitialized after top
      Curses.init_screen
      Curses.start_color
      Curses.crmode
      Curses.stdscr.keypad = true
      Curses.curs_set(0)  # hide cursor
      Curses.clear
    end

    def view_page_down
      @view_page += 1

      return unless @view_page_max && @view_page > @view_page_max

      @view_page = @view_page_max
    end

    def view_page_up
      @view_page -= 1 if @view_page > 0
    end

    def view_page_reset
      @view_page = 0
    end

    def view_page_end
      if view_page_max
        @view_page = view_page_max
      else
        view_page_down
      end
    end

    def search_start_focus
      @search_input = true

      Curses.curs_set(1)  # show cursor
      Curses.clear
    end

    def search_in_focus?
      @search_input
    end

    def search_end_focus
      Curses.curs_set(0)  # hide cursor
      @search_input = false
    end

    def search_cancel
      search_end_focus
      @search_string = ''
    end

    def search_active?
      !@search_string.empty?
    end

    def search_add(input)
      @search_string << input
    end

    def search_chop
      @search_string.chop!
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

    def mode
      model_thread.mode
    end

    def rt?
      model_thread.mode == :realtime
    end

    def format_ctid(ctid)
      if ctid.length > 12
        "#{ctid[0..11]}.."
      else
        ctid
      end
    end

    def format_loadavgs(lavgs)
      lavgs.map { |lavg| format_loadavg(lavg) }.join(', ')
    end

    def format_loadavg(lavg)
      fmt =
        if lavg < 100
          '%5.2f'
        elsif lavg < 1000
          '%5.1f'
        else
          '%4.0f'
        end

      format(fmt, lavg)
    end

    def bold
      Curses.attron(Curses::A_BOLD)
      yield
      Curses.attroff(Curses::A_BOLD)
    end

    def fill_row
      yield
      x, y = cursor
      Curses.addstr(' ' * (Curses.cols - y))
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

      m = res.match(/(?<row>\d+);(?<column>\d+)/)
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
