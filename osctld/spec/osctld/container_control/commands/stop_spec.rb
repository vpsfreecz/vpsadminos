# frozen_string_literal: true

require 'osctld/container_control/commands/stop'
require 'osctld/container_control/result'

RSpec.describe OsCtld::ContainerControl::Commands::Stop do
  subject(:frontend) do
    Class.new(described_class::Frontend) do
      attr_accessor :exec_result, :fork_result, :exec_calls, :fork_calls

      def exec_runner(**opts)
        self.exec_calls ||= []
        exec_calls << opts
        exec_result
      end

      def fork_runner(**opts)
        self.fork_calls ||= []
        fork_calls << opts
        fork_result
      end
    end.new(described_class, ct)
  end

  let(:running) { true }
  let(:ct) do
    Struct.new(:running, :cgroup_path, keyword_init: true) do
      def running?
        running
      end
    end.new(running:, cgroup_path: '/osctl/pool.tank/ct.ct1')
  end

  before do
    cgroup = stub_const('OsCtld::CGroup', Module.new)
    cgroup.define_singleton_method(:thaw_tree) { |_path| nil }
    allow(OsCtld::CGroup).to receive(:thaw_tree)
  end

  it 'rejects invalid stop modes' do
    expect { frontend.execute(:reboot) }.to raise_error(ArgumentError, /invalid stop mode/)
  end

  it 'thaws the cgroup tree before kill mode and uses the fork runner' do
    frontend.fork_result = OsCtld::ContainerControl::Result.new(true)

    expect(frontend.execute(:kill)).to be(true)
    expect(OsCtld::CGroup).to have_received(:thaw_tree).with('/osctl/pool.tank/ct.ct1')
    expect(frontend.fork_calls).to eq([{ args: [:kill, {}] }])
  end

  it 'falls back to kill when stop mode cannot shut the container down cleanly' do
    frontend.exec_result = OsCtld::ContainerControl::Result.new(false, message: 'kill required')
    frontend.fork_result = OsCtld::ContainerControl::Result.new(true)

    expect(frontend.execute(:stop)).to be(true)
    expect(OsCtld::CGroup).to have_received(:thaw_tree).with('/osctl/pool.tank/ct.ct1')
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
    expect(call[:lifecycle_owned]).to be(true)
  end
end
