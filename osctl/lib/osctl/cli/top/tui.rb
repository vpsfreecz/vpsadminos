require 'curses'
require 'osctl/cli/top/view'

module OsCtl::Cli
  class Top::Tui < Top::View
    SELECTED = 1
    HIGHLIGHTED = 2
    SELECTED_HIGHLIGHTED = 3

    def initialize(model, rate, enable_procs: true)
      super(model, rate)
      @enable_procs = enable_procs
    end

    def start
      Curses.init_screen
      Curses.start_color
      Curses.crmode
      Curses.stdscr.keypad = true
      Curses.curs_set(0) # hide cursor
      Curses.use_default_colors
      Curses.init_pair(SELECTED, Curses::COLOR_BLACK, Curses::COLOR_WHITE)
      Curses.init_pair(HIGHLIGHTED, Curses::COLOR_YELLOW, Curses::COLOR_BLACK)
      Curses.init_pair(SELECTED_HIGHLIGHTED, Curses::COLOR_RED, Curses::COLOR_WHITE)

      screen = Top::Tui::Main.new(model, rate, enable_procs: @enable_procs)

      loop do
        screen = screen.open
        break unless screen

        Curses.clear
      end
    rescue Interrupt
      # stop
    ensure
      Curses.close_screen
    end
  end
end
