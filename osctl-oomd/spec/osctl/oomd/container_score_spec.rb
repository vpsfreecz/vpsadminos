# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Oomd::ContainerScore do
  let(:score) { described_class.new('tank', 'ct') }
  let(:gate) { { load: true, rtnl: nil } }

  def observe(seconds, hit: true, gate: self.gate, load: true, linked: true, interval: 5)
    score.observe(now_ns: (seconds * 1e9).to_i, qualification: hit, gate_token: gate,
                  load_gate: load, linked:, interval_ns: (interval * 1e9).to_i)
  end

  [1, 5, 15].each do |interval|
    it "uses real covered seconds at interval #{interval}, first reading only seeds" do
      observe(100, interval:)
      expect(score.restart_qualified_seconds).to eq(0)
      (90 / interval).times { |i| observe(100 + ((i + 1) * interval), interval:) }
      expect(score.restart_qualified_seconds).to eq(90)
      expect(score.stop_qualified_seconds).to eq(90)
    end
  end

  [1, 5, 15].each do |interval|
    it "keeps independent600second stop accumulation at interval #{interval}" do
      observe(100, interval:)
      (600 / interval).times { |i| observe(100 + ((i + 1) * interval), interval:) }
      expect(score.stop_qualified_seconds).to eq(600)
    end
  end

  it 'caps both credit and 1:1 decay at the configured interval' do
    observe(100)
    observe(109)
    expect(score.restart_qualified_seconds).to eq(5)
    observe(118, hit: false)
    expect(score.restart_qualified_seconds).to eq(0)
    expect(score.stop_qualified_seconds).to eq(0)
  end

  it 'distinguishes 89.999 from 90 qualified seconds' do
    observe(100, interval: 100)
    observe(189.999, interval: 100)
    expect(score.restart_qualified_seconds).to be_within(1e-6).of(89.999)
    observe(190, interval: 100)
    expect(score.restart_qualified_seconds).to eq(90)
  end

  it 'keeps one restart score across an independently continuous load/RTNL switch' do
    observe(100)
    observe(105)
    both = { load: true, rtnl: ['epoch', 1] }
    observe(110, gate: both)
    observe(115, gate: { load: false, rtnl: ['epoch', 1] }, load: false)
    expect(score.restart_qualified_seconds).to eq(15)
    expect(score.stop_qualified_seconds).to eq(10)
    observe(120, gate: { load: false, rtnl: ['new', 2] }, load: false)
    expect(score.restart_qualified_seconds).to eq(15) # Unsupported transition omitted.
    observe(125, gate: { load: false, rtnl: ['new', 2] }, load: false)
    expect(score.restart_qualified_seconds).to eq(20)
  end

  it 'does not credit or decay unknown intervals and expires only restart evidence' do
    observe(100)
    observe(105)
    observe(110, hit: nil)
    observe(115)
    expect(score.restart_qualified_seconds).to eq(5)
    score.expire(now_ns: 145_000_000_000, expiry_ns: 30_000_000_000)
    expect(score.restart_qualified_seconds).to eq(0)
    expect(score.stop_qualified_seconds).to eq(5)
    observe(150)
    expect(score.restart_qualified_seconds).to eq(0)
  end

  it 'expires through target-valid but gate-unknown samples without healthy decay' do
    observe(100)
    observe(105)
    [110, 115, 120, 125, 130].each { |time| observe(time, gate: nil, load: false) }
    expect(score.restart_qualified_seconds).to eq(5)
    expect(score.last_usable_ns).to eq(105_000_000_000)
    score.expire(now_ns: 135_000_000_000, expiry_ns: 30_000_000_000)
    expect(score.restart_qualified_seconds).to eq(0)
    observe(140)
    expect(score.restart_qualified_seconds).to eq(0)
    observe(145)
    expect(score.restart_qualified_seconds).to eq(5)
  end

  it 'decays restart on confirmed inactivity but freezes load-only stop history' do
    observe(100)
    observe(105)
    observe(110, gate: false, load: false)
    expect(score.restart_qualified_seconds).to eq(0)
    expect(score.stop_qualified_seconds).to eq(5)
    score.reset_restart
    observe(115)
    observe(120)
    expect(score.stop_qualified_seconds).to eq(10)
    score.reset_stop
    expect(score.stop_qualified_seconds).to eq(0)
  end

  it 'grants no duplicate, unlinked or first reading backlog time' do
    observe(100)
    observe(105)
    observe(105)
    expect(score.restart_qualified_seconds).to eq(5)
    observe(200, linked: false)
    expect(score.restart_qualified_seconds).to eq(5)
  end
end
