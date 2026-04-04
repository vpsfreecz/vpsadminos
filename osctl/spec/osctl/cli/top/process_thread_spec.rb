# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Top::Tui::ProcessThread do
  it 'probes process state counts and updates timestamps' do
    p1 = double('proc', state: 'R')
    p2 = double('proc', state: 'S')
    allow(OsCtl::Lib::ProcessList).to receive(:each).with(parse_status: false).and_yield(p1).and_yield(p2)

    thread = described_class.new(0.01)
    thread.send(:probe_processes)
    stats, last_probe = thread.get_stats

    expect(stats['TOTAL']).to eq(2)
    expect(stats['R']).to eq(1)
    expect(stats['S']).to eq(1)
    expect(last_probe).to be_a(Time)
  end
end
