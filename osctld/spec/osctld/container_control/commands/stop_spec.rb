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

  let(:ct) { Struct.new(:running?, :id).new(true, 'ct1') }
  let(:forced_stop) { instance_double(OsCtld::Container::ForcedStop) }
  let(:success) { OsCtld::ContainerControl::Result.new(true) }
  let(:failure) { OsCtld::ContainerControl::Result.new(false, message: 'kill required') }

  before do
    allow(OsCtld::Container::ForcedStop).to receive(:new).with(ct).and_return(forced_stop)
    allow(forced_stop).to receive(:run) do |stop:, **|
      stop.call(50).ok?
    end
    frontend.fork_result = success
  end

  it 'rejects invalid modes without beginning forced stopping' do
    expect { frontend.execute(:reboot) }.to raise_error(ArgumentError, /invalid stop mode/)
    expect(forced_stop).not_to have_received(:run)
  end

  it 'preserves NFS retries during a successful graceful shutdown' do
    frontend.exec_result = success
    expect(frontend.execute(:shutdown, timeout: 30)).to be(true)
    expect(forced_stop).not_to have_received(:run)
  end

  it 'does not force a shutdown-only timeout' do
    frontend.exec_result = failure
    expect(frontend.execute(:shutdown, timeout: 30)).to equal(failure)
    expect(forced_stop).not_to have_received(:run)
  end

  it 'passes the shared deadline to the LXC kill runner' do
    expect(frontend.execute(:kill)).to be(true)
    expect(frontend.fork_calls).to eq([{ args: [:kill, {}], deadline: 50 }])
  end

  it 'uses the same forced-stop path after graceful shutdown fails' do
    frontend.exec_result = failure
    expect(frontend.execute(:stop)).to be(true)
    expect(frontend.fork_calls).to eq([{ args: [:kill, {}], deadline: 50 }])
    expect(forced_stop).to have_received(:run).once
  end

  it 'uses the caller-provided budget for escalation and recovery' do
    budget = instance_double(OsCtld::Container::ForcedStop, run: true)
    expect(frontend.execute(:kill, forced_stop: budget)).to be(true)
    expect(budget).to have_received(:run).once
    expect(OsCtld::Container::ForcedStop).not_to have_received(:new)
  end

  it 'surfaces an exhausted forced-stop budget' do
    allow(forced_stop).to receive(:run).and_raise(OsCtld::ContainerControl::Error, 'still running')
    expect { frontend.execute(:kill) }.to raise_error(OsCtld::ContainerControl::Error, 'still running')
  end

  it 'wraps wall messages before invoking shutdown paths' do
    allow(Socket).to receive(:gethostname).and_return('test-host')
    frontend.exec_result = success
    frontend.execute(:shutdown, message: 'maintenance', timeout: 60)
    call = frontend.exec_calls.first
    expect(call[:args].first).to eq(:shutdown)
    expect(call[:args].last[:halt_from_inside]).to be(true)
    expect(call[:args].last[:timeout]).to eq(60)
    expect(call[:args].last[:message]).to include('Message from host machine test-host')
  end
end
