# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Ps::Filter do
  let(:process) do
    double(
      'process',
      pid: 11,
      rss: 2048,
      pool: 'tank',
      ctid: 'ct1',
      state: 'R',
      cmdline: '',
      name: 'bash',
      start_time: Time.at(100),
      user_time: 2,
      sys_time: 3
    )
  end

  it 'matches numeric, bytes, time, and string filters' do
    expect(described_class.new('pid>=10').match?(process)).to be(true)
    expect(described_class.new('rss>=1K').match?(process)).to be(true)
    expect(described_class.new('time>=5').match?(process)).to be(true)
    expect(described_class.new('pool=tank').match?(process)).to be(true)
  end

  it 'supports regex filters on strings and command fallbacks' do
    expect(described_class.new('command=~bash').match?(process)).to be(true)
    expect(described_class.new('command!~zsh').match?(process)).to be(true)
  end

  it 'rejects invalid parameter names and invalid numeric regex filters' do
    expect { described_class.new('bogus=1') }.to raise_error(ArgumentError, /invalid parameter/)
    expect { described_class.new('pid=~1') }.to raise_error(ArgumentError, /cannot be used on numbers/)
  end
end
