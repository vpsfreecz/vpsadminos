# frozen_string_literal: true

require 'osctld/devices/mode'

RSpec.describe OsCtld::Devices::Mode do
  it 'normalizes, compares, and complements modes' do
    mode = described_class.new('mwrw')

    expect(mode.mode).to eq(%w[m r w])
    expect(mode.to_s).to eq('rwm')
    expect(mode.compatible?(described_class.new('rw'))).to be(true)
    expect(mode.compatible?(described_class.new('rwm'))).to be(true)
    expect(described_class.new('rw').compatible?(described_class.new('rwm'))).to be(false)

    partial = described_class.new('r')
    partial.complement(described_class.new('wm'))
    expect(partial.to_s).to eq('rwm')
  end

  it 'produces diffs, clones, and equality by normalized content' do
    source = described_class.new('rm')
    target = described_class.new('wm')

    expect(source.diff(target)).to eq(allow: 'w', deny: 'r')
    expect(source.clone).to eq(source)
    expect(described_class.new('wr')).to eq(described_class.new('rw'))
  end
end
