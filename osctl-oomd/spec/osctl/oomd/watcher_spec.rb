# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Oomd::Watcher do
  let(:controller) { instance_double(OsCtl::Oomd::Controller, start: nil, stop: nil, tick: nil, observe: nil, invalidate: nil) }
  let(:exporter) { instance_double(OsCtl::Oomd::Exporter, start: nil, stop: nil) }
  let(:watcher) do
    described_class.new(interval: 15, cpu_percent: 90, memory_percent: 95, load_multiplier: 2,
                        load_top: 5, restart_after_seconds: 90, stop_after_seconds: 600, export_file: '/tmp/unused.prom')
  end

  before do
    allow(OsCtl::Oomd::Controller).to receive(:new).and_return(controller)
    allow(OsCtl::Oomd::Exporter).to receive(:new).and_return(exporter)
  end

  it 'ticks independently if its only subscriber does not deliver a sample' do
    stopping = Class.new(StandardError)
    allow(Thread).to receive(:new).and_return(instance_double(Thread))
    allow(watcher).to receive(:sleep).with(0.25).and_raise(stopping)
    expect { watcher.run }.to raise_error(stopping)
    expect(controller).to have_received(:tick).once
    expect(controller).not_to have_received(:observe)
    expect(controller).to have_received(:stop).once
  end

  [
    [[{}, { 'sequence' => 2 }], [{ 'sequence' => 2 }]],
    [[{ 'sequence' => 1 }, {}], []],
    [[{ 'sequence' => 1 }, { 'sequence' => 1, 'conflicting' => true }], [{ 'sequence' => 1, 'conflicting' => true }]]
  ].each_with_index do |(stream, admitted), i|
    it "preserves the stream cut before the coalesced result (case #{i + 1})" do
      stopping = Class.new(StandardError)
      callbacks = []
      allow(controller).to receive(:invalidate) { callbacks << :cut }
      allow(controller).to receive(:observe) { |packet| callbacks << packet }
      allow(OsCtl::Oomd::CtTop).to receive(:run).with(15) { |_, &block| stream.each(&block) }
      allow(Thread).to receive(:new).and_yield
      allow(watcher).to receive(:sleep).with(0.25).and_raise(stopping)
      expect { watcher.run }.to raise_error(stopping)
      expect(callbacks).to eq([:cut, *admitted])
      expect(OsCtl::Oomd::CtTop).to have_received(:run).once
    end
  end
end
