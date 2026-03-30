# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/sys_conf'

RSpec.describe OsCtl::Lib::SysConf do
  around do |example|
    reset_module_ivars(described_class.instance, :@values)
    described_class.instance.send(:initialize)
    example.run
    reset_module_ivars(described_class.instance, :@values)
    described_class.instance.send(:initialize)
  end

  it 'looks up and memoizes known sysconf values' do
    allow(Etc).to receive(:sysconf).with(Etc::SC_PAGESIZE).and_return(4096)
    allow(Etc).to receive(:sysconf).with(Etc::SC_CLK_TCK).and_return(100)

    expect(described_class.page_size).to eq(4096)
    expect(described_class.page_size).to eq(4096)
    expect(described_class.tics_per_second).to eq(100)
    expect(described_class.tics_per_second).to eq(100)
    expect(Etc).to have_received(:sysconf).with(Etc::SC_PAGESIZE).once
    expect(Etc).to have_received(:sysconf).with(Etc::SC_CLK_TCK).once
  end

  it 'raises for unknown keys' do
    expect do
      described_class.instance.get(:unknown)
    end.to raise_error(ArgumentError, /not known/)
  end
end
