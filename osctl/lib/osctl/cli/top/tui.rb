require 'curses'

module OsCtl::Cli
  class Top::Tui < Top::View
    def start
      Curses.init_screen
      Curses.start_color
      Curses.crmode
      Curses.stdscr.keypad = true
      Curses.curs_set(0)  # hide cursor
      Curses.use_default_colors
      Curses.init_pair(1, Curses::COLOR_BLACK, Curses::COLOR_WHITE)

      screen = Top::Tui::Main.new(model, rate)

      loop do
        screen = screen.open
        break unless screen

        Curses.clear
      end

    rescue Interrupt
    ensure
      Curses.close_screen
    end
  end
end
