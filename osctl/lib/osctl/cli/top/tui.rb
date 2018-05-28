require 'curses'
require 'osctl/cli/top/view'

module OsCtl::Cli
  class Top::Tui < Top::View
    SELECTED = 1
    YANKED = 2
    SELECTED_YANKED = 3

    def start
      Curses.init_screen
      Curses.start_color
      Curses.crmode
      Curses.stdscr.keypad = true
      Curses.curs_set(0)  # hide cursor
      Curses.use_default_colors
      Curses.init_pair(SELECTED, Curses::COLOR_BLACK, Curses::COLOR_WHITE)
      Curses.init_pair(YANKED, Curses::COLOR_YELLOW, Curses::COLOR_BLACK)
      Curses.init_pair(SELECTED_YANKED, Curses::COLOR_RED, Curses::COLOR_WHITE)

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
