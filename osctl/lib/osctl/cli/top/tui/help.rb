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
        when 'q', '?', Tui::Key::ESCAPE
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

      pos = 0

      [
        ['q', 'Quit'],
        ['<, >, left, right', 'Change sort column'],
        ['r, R', 'Reverse sort order'],
        ['up, down', 'Select containers'],
        ['space', 'Highlight selected container'],
        ['enter, t', 'Open top and filter container processes'],
        ['h', 'Open htop and filter container processes'],
        ['PageDown', 'Scroll down'],
        ['PageUp', 'Scroll up'],
        ['Home', 'Scroll to the top'],
        ['End', 'Scroll to the bottom'],
        ['m', 'Toggle between realtime and cumulative mode'],
        ['p', 'Pause/unpause resource tracking'],
        ['/', 'Filter containers by ID. Confirm by enter, cancel by esc'],
        ['?', 'Show/hide this help message']
      ].each_with_index do |arr, i|
        key, desc = arr

        Curses.setpos(i + 2, 4)
        Curses.addstr(format('%20s - %s', key, desc))

        pos = i + 2
      end

      Curses.setpos(pos + 2, 0)
      Curses.addstr("Press 'q', '?' or <Esc> to continue")
    end
  end
end
