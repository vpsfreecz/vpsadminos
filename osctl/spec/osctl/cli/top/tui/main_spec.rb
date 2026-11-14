# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Top::Tui::Main do
  subject(:screen) { described_class.allocate }

  describe '#view_window' do
    it 'paginates when only one container row fits' do
      expect(screen.send(:view_window, 10, 1, 99)).to eq([9, 1, 9, 9])
    end

    it 'does not paginate when no container row fits' do
      expect(screen.send(:view_window, 10, 0, 3)).to eq([0, 0, 0, 0])
    end

    it 'does not create a negative page maximum when all containers fit' do
      expect(screen.send(:view_window, 3, 10, 2)).to eq([0, 10, 0, 0])
    end
  end

  def setup_screen(netif:, zfs:)
    allow(Curses).to receive(:cols).and_return(120)
    model_thread = double(mode: :realtime, netif_enabled?: netif, zfs_enabled?: zfs, iostat_enabled?: zfs)
    screen.instance_variable_set(:@model_thread, model_thread)
    screen.send(:setup_modules)
  end

  it 'omits disabled optional modules, sortable fields and totals' do
    setup_screen(netif: false, zfs: false)
    modules = screen.instance_variable_get(:@modules)
    expect(modules.map(&:name)).to eq(%w[ctid cpu memory proc loadavg])
    fields = screen.send(:sortable_fields)
    expect(fields).not_to include(%i[tx bytes], %i[rx bytes], %i[zfsio bytes r])
  end

  it 'preserves ordinary optional modules and renders unavailable totals as unknown' do
    setup_screen(netif: true, zfs: true)
    modules = screen.instance_variable_get(:@modules)
    expect(modules.map(&:name)).to eq(%w[ctid cpu memory proc zfsio network loadavg])
    network = modules.detect { |m| m.name == 'network' }
    rows = [{ id: 'ct1', tx: nil, rx: nil }]
    expect(screen.send(:module_totals, network, rows, {}, true)).to eq(['-'] * 4)
  end

  it 'can sort warming core rows without inventing zero CPU usage' do
    setup_screen(netif: false, zfs: false)
    screen.instance_variable_set(:@last_data, { containers: [{ id: 'one', cpu_usage: nil }, { id: 'two', cpu_usage: 1 }] })
    screen.instance_variable_set(:@sort_index, 0)
    screen.instance_variable_set(:@sort_desc, true)
    expect { screen.send(:run_sort) }.not_to raise_error
    expect(screen.instance_variable_get(:@last_data)[:containers].map { |ct| ct[:cpu_usage] }).to eq([1, nil])
  end

  it 'renders incomplete null core and optional row values as unknown' do
    setup_screen(netif: true, zfs: true)
    allow(Curses).to receive(:addstr)
    allow(Curses).to receive(:attron)
    allow(Curses).to receive(:attroff)
    screen.instance_variable_set(:@sort_index, 0)
    row = { id: '[host]', cpu_usage: nil, memory: nil, nproc: nil, loadavg: nil,
            tx: nil, rx: nil, zfsio: nil }
    expect { screen.send(:print_row, row) }.not_to raise_error
    expect(Curses).to have_received(:addstr).with(a_string_including('-')).at_least(:once)
  end
end
