# frozen_string_literal: true

require 'osctld/container/nfs_cancellation'
require 'osctld/container_control/commands/stop'
require 'osctld/container_control/result'

RSpec.describe OsCtld::ContainerControl::Commands::Stop do
  subject(:frontend) do
    Class.new(described_class::Frontend) do
      attr_accessor :exec_result, :fork_result, :exec_calls, :fork_calls, :call_trace

      def exec_runner(**opts)
        self.exec_calls ||= []
        exec_calls << opts
        exec_result
      end

      def fork_runner(**opts)
        call_trace&.push([:runner, opts])
        self.fork_calls ||= []
        fork_calls << opts
        fork_result
      end
    end.new(described_class, ct)
  end

  let(:running) { true }
  let(:cancellation) { instance_double(OsCtld::Container::NfsCancellation, capture: nil, abort: 0) }
  let(:run_conf) { Struct.new(:init_pid, :nfs_cancellation).new(123, cancellation) }
  let(:ct) do
    Struct.new(:running, :id, :cgroup_path, :get_run_conf, keyword_init: true) do
      def running?
        running
      end
    end.new(running:, id: 'ct1', cgroup_path: '/osctl/pool.tank/ct.ct1', get_run_conf: run_conf)
  end

  let(:payload) { '/osctl/pool.tank/ct.ct1/lxc.payload.ct1' }

  before do
    cgroup = stub_const('OsCtld::CGroup', Module.new)
    cgroup.define_singleton_method(:thaw_tree) { |_path| nil }
    cgroup.define_singleton_method(:freeze_tree) { |_path| nil }
    cgroup.define_singleton_method(:wait_frozen) { |_path| nil }
    allow(OsCtld::CGroup).to receive(:thaw_tree)
    allow(OsCtld::CGroup).to receive(:freeze_tree)
    allow(OsCtld::CGroup).to receive(:wait_frozen)
  end

  it 'rejects invalid stop modes' do
    expect { frontend.execute(:reboot) }.to raise_error(ArgumentError, /invalid stop mode/)
    expect(cancellation).not_to have_received(:abort)
  end

  it 'preserves NFS retries during a successful graceful shutdown' do
    frontend.exec_result = OsCtld::ContainerControl::Result.new(true)

    expect(frontend.execute(:shutdown, timeout: 30)).to be(true)
    expect(cancellation).not_to have_received(:abort)
    expect(OsCtld::CGroup).not_to have_received(:freeze_tree)
  end

  it 'does not abort NFS when shutdown-only mode times out' do
    frontend.exec_result = OsCtld::ContainerControl::Result.new(false, message: 'timeout')

    expect(frontend.execute(:shutdown, timeout: 30)).to equal(frontend.exec_result)
    expect(cancellation).not_to have_received(:abort)
  end

  it 'captures identity then cancels before invoking the forced-stop runner' do
    frontend.fork_result = OsCtld::ContainerControl::Result.new(true)
    calls = []
    allow(cancellation).to receive(:capture) { |pid| calls << [:capture, pid] }
    allow(OsCtld::CGroup).to receive(:thaw_tree) { |path| calls << [:thaw, path] }
    allow(OsCtld::CGroup).to receive(:freeze_tree) { |path| calls << [:freeze, path] }
    allow(cancellation).to receive(:abort) { calls << [:abort] }
    allow(OsCtld::CGroup).to receive(:wait_frozen) { |path| calls << [:wait, path] }
    frontend.call_trace = calls

    expect(frontend.execute(:kill)).to be(true)
    expect(calls).to eq([
                          [:capture, 123], [:thaw, ct.cgroup_path], [:freeze, payload],
                          [:abort], [:wait, payload], [:abort],
                          [:runner, { args: [:kill, {}] }], [:thaw, payload]
                        ])
  end

  it 'thaws the container and surfaces a failed cancellation' do
    allow(cancellation).to receive(:abort).and_raise('cancellation failed')

    expect { frontend.execute(:kill) }.to raise_error('cancellation failed')
    expect(OsCtld::CGroup).to have_received(:thaw_tree).with(payload)
    expect(frontend.fork_calls).to be_nil
  end

  it 'keeps only the payload frozen until the forced-stop runner returns' do
    frontend.fork_result = OsCtld::ContainerControl::Result.new(true)

    expect(frontend.execute(:kill)).to be(true)
    expect(OsCtld::CGroup).to have_received(:thaw_tree).with(payload)
    expect(frontend.fork_calls).to eq([{ args: [:kill, {}] }])
  end

  it 'falls back to kill when stop mode cannot shut the container down cleanly' do
    frontend.exec_result = OsCtld::ContainerControl::Result.new(false, message: 'kill required')
    frontend.fork_result = OsCtld::ContainerControl::Result.new(true)

    expect(frontend.execute(:stop)).to be(true)
    expect(cancellation).to have_received(:abort).twice
    expect(OsCtld::CGroup).to have_received(:thaw_tree).with(payload)
    expect(frontend.fork_calls).to eq([{ args: [:kill, {}] }])
  end

  it 'wraps wall messages before invoking shutdown paths' do
    allow(Socket).to receive(:gethostname).and_return('test-host')
    frontend.exec_result = OsCtld::ContainerControl::Result.new(true)

    frontend.execute(:shutdown, message: 'maintenance', timeout: 60)

    call = frontend.exec_calls.first

    expect(call[:args].first).to eq(:shutdown)
    expect(call[:args].last[:halt_from_inside]).to be(true)
    expect(call[:args].last[:timeout]).to eq(60)
    expect(call[:args].last[:message]).to include('Message from host machine test-host')
  end
end
