# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Oomd::Eligibility do
  let(:container) do
    { 'pool' => 'tank', 'id' => 'a', 'memory' => 95, 'memory_limit' => 100,
      'cpu_usage' => 90.0, 'cpu_limit' => 100 }
  end
  let(:limits) { { memory_percent: 95, cpu_percent: 90, load_top: 2 } }

  def eligible?(ct = container, ranked = [ct], **overrides)
    described_class.hit?(ct, ranked, **limits, **overrides)
  end

  it 'rejects an absent memory limit before considering other inputs' do
    expect(eligible?(container.merge('memory_limit' => nil, 'cpu_usage' => nil))).to be(false)
  end

  it 'retains floating-point memory arithmetic and inclusive equality thresholds' do
    expect(eligible?).to be(true)
  end

  it 'rejects memory below the configured percentage' do
    expect(eligible?(container.merge('memory' => 94))).to be(false)
  end

  it 'retains nil memory conversion to zero' do
    expect(eligible?(container.merge('memory' => nil))).to be(false)
  end

  it 'skips CPU arithmetic when the CPU limit is absent' do
    expect(eligible?(container.merge('cpu_limit' => nil, 'cpu_usage' => nil))).to be(true)
  end

  it 'rejects limited CPU usage below the configured percentage' do
    expect(eligible?(container.merge('cpu_usage' => 89.9))).to be(false)
  end

  it 'does not introduce CPU numeric coercion' do
    expect(eligible?(container.merge('cpu_usage' => 90))).to be(false)
  end

  it 'matches copied ranked rows by pool and id' do
    expect(eligible?(container, [{ 'pool' => 'tank', 'id' => 'a' }])).to be(true)
  end

  it 'does not match the same id from another pool' do
    ranked = [{ 'pool' => 'other', 'id' => 'a' },
              { 'pool' => 'tank', 'id' => 'b' },
              { 'pool' => 'tank', 'id' => 'a' }]
    expect(eligible?(container, ranked)).to be(false)
  end

  it 'rejects a missing rank' do
    expect(eligible?(container, [])).to be(false)
  end

  it 'includes the synthetic host row when applying the rank cutoff' do
    ranked = [{ 'pool' => nil, 'id' => '[host]' }, container]
    expect(eligible?(container, ranked, load_top: 1)).to be(false)
    expect(eligible?(container, ranked, load_top: 2)).to be(true)
  end
end
