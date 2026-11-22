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

  it 'marks a measured subtotal per field but preserves independent node totals' do
    setup_screen(netif: false, zfs: false)
    modules = screen.instance_variable_get(:@modules).to_h { |mod| [mod.name, mod] }
    data = { top_schema: 2, inventory_complete: true, node_totals: { memory: 64 * (1024**2), cpu_usage: 50 } }
    rows = [{ id: 'one', memory: 8 * (1024**2), cpu_usage: 0 }, { id: 'two', memory: 4 * (1024**2) }, { id: '[host]' }]
    expect(screen.send(:module_totals, modules.fetch('cpu'), rows, data, false)).to eq(['~0'])
    expect(screen.send(:module_totals, modules.fetch('cpu'), rows, data, true)).to eq(['50'])
    expect(screen.send(:module_totals, modules.fetch('memory'), rows, data, false)).to eq(['12.0M'])
    data[:inventory_complete] = false
    expect(screen.send(:module_totals, modules.fetch('memory'), rows, data, false)).to eq(['~12.0M'])
    expect(screen.send(:module_totals, modules.fetch('memory'), rows, data, true)).to eq(['64.0M'])
    expect(screen.send(:module_totals, modules.fetch('loadavg'), rows, data, true)).to eq(['-'] * 3)
  end

  it 'does not add cumulative readings with different origins' do
    setup_screen(netif: false, zfs: false)
    allow(screen.send(:model_thread)).to receive(:mode).and_return(:cumulative)
    cpu = screen.instance_variable_get(:@modules).find { |mod| mod.name == 'cpu' }
    rows = [{ id: 'one', cpu_us: 20, column_windows: { cpu_us: 15 } },
            { id: 'two', cpu_us: 10, column_windows: { cpu_us: 30 } }]
    expect(screen.send(:module_totals, cpu, rows, { top_schema: 2, inventory_complete: true }, false)).to eq(['-'])
  end

  it 'can sort warming core rows without inventing zero CPU usage' do
    setup_screen(netif: false, zfs: false)
    screen.instance_variable_set(:@last_data, { containers: [{ id: 'one', cpu_usage: nil }, { id: 'two', cpu_usage: 1 }] })
    screen.instance_variable_set(:@sort_index, 0)
    screen.instance_variable_set(:@sort_desc, true)
    expect { screen.send(:run_sort) }.not_to raise_error
    expect(screen.instance_variable_get(:@last_data)[:containers].map { |ct| ct[:cpu_usage] }).to eq([1, nil])
  end

  it 'does not enter the pinned namespace if the recheck fails' do
    setup_screen(netif: false, zfs: false)
    ns = instance_double(File)
    allow(File).to receive(:open).with('/proc/123/ns/pid', 'r').and_yield(ns)
    thread = screen.send(:model_thread)
    allow(thread).to receive(:current_run?).with({ init_pid: 123 }, pid_namespace: ns).and_return(false)
    allow(Process).to receive(:fork)
    expect(screen.send(:open_container_program, { init_pid: 123 }) { ['top'] }).to be_nil
    expect(Process).not_to have_received(:fork)
  end

  it 'renders a relaunch instruction when event monitoring is lost' do
    setup_screen(netif: false, zfs: false)
    allow(Curses).to receive_messages(lines: 17, setpos: nil, addstr: nil, refresh: nil, attron: nil, attroff: nil, color_pair: 0)
    screen.instance_variable_set(:@containers, [])
    screen.send(:render, Time.at(1), nil, { containers: [], invalid_reason: 'monitor_unavailable' })
    expect(Curses).to have_received(:addstr).with('Event monitoring lost. Relaunch ct top.')
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
