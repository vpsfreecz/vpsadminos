# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Top::Tui do
  it 'initializes curses and always closes the screen' do
    screen = instance_double(OsCtl::Cli::Top::Tui::Main, open: nil)
    allow(Curses).to receive(:init_screen)
    allow(Curses).to receive(:start_color)
    allow(Curses).to receive(:crmode)
    allow(Curses).to receive(:stdscr).and_return(double('stdscr', 'keypad=': nil))
    allow(Curses).to receive(:curs_set)
    allow(Curses).to receive(:use_default_colors)
    allow(Curses).to receive(:init_pair)
    allow(Curses).to receive(:clear)
    allow(Curses).to receive(:close_screen)
    allow(OsCtl::Cli::Top::Tui::Main).to receive(:new).and_return(screen)

    described_class.new(double('model'), 1).start

    expect(Curses).to have_received(:close_screen)
  end

  it 'handles interrupts cleanly' do
    allow(Curses).to receive_messages(
      init_screen: nil,
      start_color: nil,
      crmode: nil,
      stdscr: double('stdscr', 'keypad=': nil),
      curs_set: nil,
      use_default_colors: nil,
      init_pair: nil,
      close_screen: nil
    )
    screen = instance_double(OsCtl::Cli::Top::Tui::Main)
    allow(screen).to receive(:open).and_raise(Interrupt)
    allow(OsCtl::Cli::Top::Tui::Main).to receive(:new).and_return(screen)

    expect { described_class.new(double('model'), 1).start }.not_to raise_error
  end
end
