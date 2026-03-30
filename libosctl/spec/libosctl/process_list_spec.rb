# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/exceptions'
require 'libosctl/process_list'

RSpec.describe OsCtl::Lib::ProcessList do
  let(:host_process) { instance_double(OsCtl::Lib::OsProcess, pid: 100) }
  let(:other_process) { instance_double(OsCtl::Lib::OsProcess, pid: 300) }

  before do
    allow(Dir).to receive(:foreach).with('/proc').and_yield('.').and_yield('abc').and_yield('100').and_yield('200').and_yield('300')
    allow(Dir).to receive(:exist?).with('/proc/100').and_return(true)
    allow(Dir).to receive(:exist?).with('/proc/200').and_return(true)
    allow(Dir).to receive(:exist?).with('/proc/300').and_return(true)
    allow(OsCtl::Lib::OsProcess).to receive(:new).with(100, parse_stat: false).and_return(host_process)
    allow(OsCtl::Lib::OsProcess).to receive(:new).with(200, parse_stat: false).and_raise(
      OsCtl::Lib::Exceptions::OsProcessNotFound,
      'process 200 not found'
    )
    allow(OsCtl::Lib::OsProcess).to receive(:new).with(300, parse_stat: false).and_return(other_process)
  end

  it 'lists numeric proc entries only, skips vanished processes, and supports filtering' do
    list = described_class.new(parse_stat: false) { |process| process.pid == 100 }

    expect(list.map(&:pid)).to eq([100])
  end

  it 'iterates through processes without keeping them on the class helper' do
    seen = []

    expect(described_class.each(parse_stat: false) { |process| seen << process.pid }).to be_nil
    expect(seen).to eq([100, 300])
  end
end
