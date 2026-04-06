# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::Cli::LabelFilters do
  it 'supports equality filters' do
    script = instance_double(TestRunner::TestScript, labels: { 'distro' => 'nixos' })

    expect(described_class.new(['distro=nixos']).pass?(script)).to be(true)
  end

  it 'supports inequality filters' do
    script = instance_double(TestRunner::TestScript, labels: { 'tier' => 'slow' })

    expect(described_class.new(['tier!=fast']).pass?(script)).to be(true)
  end

  it 'ands multiple filters together' do
    script = instance_double(TestRunner::TestScript, labels: { 'distro' => 'nixos', 'tier' => 'smoke' })

    expect(described_class.new(['distro=nixos', 'tier=smoke']).pass?(script)).to be(true)
    expect(described_class.new(['distro=nixos', 'tier=full']).pass?(script)).to be(false)
  end

  it 'raises on invalid filter strings' do
    expect do
      described_class.new(['invalid'])
    end.to raise_error(GLI::BadCommandLine, "Invalid filter 'invalid'")
  end

  it 'evaluates filters against the passed test script' do
    script = instance_double(TestRunner::TestScript, labels: { 'distro' => 'nixos', 'tier' => 'smoke' })

    filters = described_class.new(['distro=nixos', 'tier!=slow'])

    expect(filters.pass?(script)).to be(true)
  end
end
