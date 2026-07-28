# frozen_string_literal: true

require 'osctld/dist_config'

RSpec.describe OsCtld::DistConfig do
  let(:run_config_class) do
    Class.new do
      def distribution; end

      def mount; end

      def log(*); end
    end
  end

  around do |example|
    original_dists = described_class.instance_variable_get(:@dists)
    described_class.instance_variable_set(:@dists, original_dists ? original_dists.dup : {})
    example.run
    described_class.instance_variable_set(:@dists, original_dists)
  end

  it 'registers and resolves distribution classes' do
    klass = Class.new

    described_class.register(:alpine, klass)

    expect(described_class.for(:alpine)).to be(klass)
  end

  it 'mounts before non-stop commands and invokes the distribution handler' do
    ctrc = instance_double(run_config_class, distribution: 'alpine', mount: nil, log: nil)
    dist_class = Class.new do
      def initialize(_ctrc); end

      def start(_opts); end
    end
    dist = instance_double(dist_class, start: nil)

    described_class.register(:alpine, dist_class)
    allow(dist_class).to receive(:new).with(ctrc).and_return(dist)

    described_class.run(ctrc, :start, init: true)

    expect(ctrc).to have_received(:mount).once
    expect(dist).to have_received(:start).with(init: true)
  end

  it 'skips mounting for stop commands' do
    ctrc = instance_double(run_config_class, distribution: 'alpine', mount: nil, log: nil)
    dist_class = Class.new do
      def initialize(_ctrc); end

      def stop(_opts); end
    end
    dist = instance_double(dist_class, stop: nil)

    described_class.register(:alpine, dist_class)
    allow(dist_class).to receive(:new).with(ctrc).and_return(dist)

    described_class.run(ctrc, :stop)

    expect(ctrc).not_to have_received(:mount)
    expect(dist).to have_received(:stop).with({})
  end

  it 'logs and swallows distribution errors' do
    ctrc = instance_double(run_config_class, distribution: 'alpine', mount: nil, log: nil)
    dist_class = Class.new do
      def initialize(_ctrc); end

      def start(_opts); end
    end
    dist = instance_double(dist_class)

    described_class.register(:alpine, dist_class)
    allow(dist_class).to receive(:new).with(ctrc).and_return(dist)
    allow(dist).to receive(:start).and_raise(StandardError, 'boom')

    expect { described_class.run(ctrc, :start) }.not_to raise_error
    expect(ctrc).to have_received(:mount).once
    expect(ctrc).to have_received(:log).with(:warn, 'DistConfig.start failed: boom')
  end

  it 'reports handler completion separately from the legacy return value' do
    ctrc = instance_double(run_config_class, distribution: 'alpine', mount: nil, log: nil)
    dist_class = Class.new do
      def initialize(_ctrc); end

      def start(_opts)
        :started
      end
    end

    described_class.register(:alpine, dist_class)

    expect(described_class.run_with_status(ctrc, :start)).to eq([true, :started])
    expect(described_class.run(ctrc, :start)).to eq(:started)
  end

  it 'reports a suppressed distribution error to status-aware callers' do
    ctrc = instance_double(run_config_class, distribution: 'alpine', mount: nil, log: nil)
    dist_class = Class.new do
      def initialize(_ctrc); end

      def start(_opts)
        raise 'boom'
      end
    end

    described_class.register(:alpine, dist_class)
    allow(described_class).to receive(:denixstorify).and_return(['trace'])

    expect(described_class.run_with_status(ctrc, :start)).to eq([false, nil])
  end
end
