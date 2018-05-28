require 'curses'
require 'osctl/cli/top/tui/screen'

module OsCtl::Cli::Top
  class Tui::Help < Tui::Screen
    def initialize(main_screen)
      @main_screen = main_screen
    end

    def open
      loop do
        render

        case Curses.getch
        when 'q', '?', 27 # Escape
          return @main_screen

        when Curses::Key::RESIZE
          Curses.clear
        end
      end
    end

    protected
    def render
      Curses.setpos(0, 0)
      Curses.addstr('Key bindings:')

      [
        ['q', 'Quit'],
        ['<, >, left, right', 'Change sort column'],
        ['r, R', 'Reverse sort order'],
        ['up, down', 'Select containers'],
        ['space', 'Yank selected container'],
        ['enter', 'Open htop and filter container processes'],
        ['m', 'Toggle between realtime and cumulative mode'],
        ['?', 'Show/hide this help message'],
      ].each_with_index do |arr, i|
        key, desc = arr

        Curses.setpos(i+2, 4)
        Curses.addstr(sprintf('%20s - %s', key, desc))
      end

      Curses.setpos(8, 0)
      Curses.addstr("Press 'q', '?' or <Esc> to continue")
    end
  end
end
