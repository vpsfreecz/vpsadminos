# frozen_string_literal: true

require 'osctld/console'
require 'osctld/console/console'
require 'osctld/container'
require 'osctld/container/lifecycle'
require 'osctld/container/run_id'
require 'osctld/container/run_configuration'

RSpec.describe OsCtld::Console::Console do
  let(:run_id) do
    OsCtld::Container::RunId.new(
      pool_name: 'tank',
      container_id: 'ct1',
      key: 'a' * 32
    )
  end
  let(:run_conf) do
    instance_double(OsCtld::Container::RunConfiguration, run_id:)
  end
  let(:lifecycle) do
    instance_double(
      OsCtld::Container::Lifecycle,
      active_run_id: run_id,
      observe_wrapper_gone: false
    )
  end
  let(:ct) { instance_double(OsCtld::Container, lifecycle:) }
  let(:daemon) do
    Class.new do
      def stopping? = false
    end.new
  end

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
    daemon_class = stub_const('OsCtld::Daemon', Class.new do
      def self.get; end
    end)
    allow(daemon_class).to receive(:get).and_return(daemon)
  end

  it 'keeps open as a no-op for tty0' do
    expect(described_class.new(ct, 0).open).to be_nil
  end

  it 'retries socket races without imposing a lifecycle timeout' do
    console = described_class.new(ct, 0)
    socket = instance_double(UNIXSocket)
    attempts = [Errno::ENOENT, Errno::ECONNREFUSED, socket]
    allow(console).to receive(:wake)
    allow(console).to receive(:sleep)
    allow(UNIXSocket).to receive(:new) do
      ret = attempts.shift
      raise ret if ret.is_a?(Class)

      ret
    end

    console.connect(nil, '/tmp/tty0.sock', run_conf)

    expect(console.send(:tty_in_io)).to equal(socket)
    expect(console.send(:tty_run_conf)).to equal(run_conf)
    expect(console).to have_received(:sleep).twice
  end

  it 'stops retrying when the exact wrapper exits' do
    console = described_class.new(ct, 0)
    identity = instance_double(OsCtld::ProcessIdentity, alive?: false)
    allow(OsCtld::ProcessIdentity).to receive(:capture).with(123).and_return(identity)
    allow(UNIXSocket).to receive(:new).and_raise(Errno::ENOENT)

    expect do
      console.connect(123, '/tmp/tty0.sock', run_conf)
    end.to raise_error(RuntimeError, /wrapper exited/)
    expect(lifecycle).to have_received(:observe_wrapper_gone).with(run_id)
  end

  it 'rejects a console connection after a newer generation takes the slot' do
    console = described_class.new(ct, 0)
    allow(lifecycle).to receive(:active_run_id).and_return(run_id, nil)
    allow(UNIXSocket).to receive(:new).and_raise(Errno::ENOENT)

    expect do
      console.connect(nil, '/tmp/tty0.sock', run_conf)
    end.to raise_error(RuntimeError, /superseded lifecycle run/)
  end

  it 'closes the old descriptor after installing a replacement connection' do
    console = described_class.new(ct, 0)
    old_socket = instance_double(UNIXSocket, close: nil)
    new_socket = instance_double(UNIXSocket)
    console.send(:tty_in_io=, old_socket)
    console.send(:tty_out_io=, old_socket)
    allow(console).to receive(:wake)
    allow(UNIXSocket).to receive(:new).and_return(new_socket)

    console.connect(nil, '/tmp/tty0.sock', run_conf)

    expect(old_socket).to have_received(:close).once
    expect(console.send(:tty_out_io)).to equal(new_socket)
  end

  it 'stops retrying when a newer lifecycle intent supersedes start' do
    console = described_class.new(ct, 0)
    identity = instance_double(OsCtld::ProcessIdentity, alive?: true)
    allow(OsCtld::ProcessIdentity).to receive(:capture).with(123).and_return(identity)
    allow(lifecycle).to receive(:effect_current?).and_return(true)
    allow(lifecycle).to receive(:current_intent_id).and_return(
      'intent-1',
      'intent-2'
    )
    allow(UNIXSocket).to receive(:new).and_raise(Errno::ENOENT)

    expect do
      console.connect(
        123,
        '/tmp/tty0.sock',
        run_conf,
        effect_id: 'effect-1',
        intent_id: 'intent-1'
      )
    end.to raise_error(RuntimeError, /superseded lifecycle run/)
  end

  it 'does not treat console EOF as wrapper exit' do
    console = described_class.new(ct, 0)

    expect(console.send(:on_close, run_conf)).to be_nil

    expect(lifecycle).not_to have_received(:observe_wrapper_gone)
  end
end
