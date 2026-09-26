# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/utils/switch_user'
require 'osctld/console'
require 'osctld/console/console'

RSpec.describe OsCtld::Console::Console do
  def build_ct(ephemeral: false, manipulated: false)
    pool = Struct.new(:name).new('tank')
    Struct.new(:pool, :id, :ephemeral, :manipulated, :run_conf, keyword_init: true) do
      def ephemeral?
        ephemeral
      end

      def is_being_manipulated?
        manipulated
      end

      def unmount(force:); end

      def mount(force:); end
    end.new(pool:, id: 'ct1', ephemeral:, manipulated:, run_conf: Object.new)
  end

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  it 'keeps open as a no-op for tty0' do
    console = described_class.new(build_ct, 0)

    expect(console.open).to be_nil
  end

  it 'retries UNIX socket connection races until they succeed' do
    console = described_class.new(build_ct, 0)
    socket = instance_double(UNIXSocket)
    attempts = [Errno::ENOENT, Errno::ECONNREFUSED, socket]
    allow(console).to receive(:wake)
    allow(console).to receive(:sleep)
    allow(UNIXSocket).to receive(:new) do
      ret = attempts.shift
      raise ret if ret.is_a?(Class)

      ret
    end

    console.connect(123, '/tmp/tty0.sock')

    expect(console.instance_variable_get(:@opened)).to be(true)
    expect(console.send(:tty_pid)).to eq(123)
    expect(console.send(:tty_in_io)).to equal(socket)
    expect(console.send(:tty_out_io)).to equal(socket)
    expect(console).to have_received(:wake)
    expect(console).to have_received(:sleep).twice
  end

  it 'raises when tty0 never becomes available' do
    console = described_class.new(build_ct, 0)
    allow(console).to receive(:sleep)
    allow(UNIXSocket).to receive(:new).and_raise(Errno::ENOENT)

    expect { console.connect(123, '/tmp/tty0.sock') }.to raise_error(Errno::ENOENT)
  end

  it 'raises when tty0 keeps refusing connections' do
    console = described_class.new(build_ct, 0)
    allow(console).to receive(:sleep)
    allow(UNIXSocket).to receive(:new).and_raise(Errno::ECONNREFUSED)

    expect { console.connect(123, '/tmp/tty0.sock') }.to raise_error(Errno::ECONNREFUSED)
  end

  it 'tracks the exact run even when connecting tty0 fails' do
    ct = build_ct
    console = described_class.new(ct, 0)
    allow(console).to receive(:sleep)
    allow(UNIXSocket).to receive(:new).and_raise(Errno::ENOENT)

    expect { console.connect(123, '/tmp/tty0.sock') }.to raise_error(Errno::ENOENT)
    expect(console.handles_run?(ct.run_conf)).to be(true)
    expect(console.handles_run?(Object.new)).to be(false)
  end

  it 'schedules the shared stop handler for the exact console run' do
    ct = build_ct
    console = described_class.new(ct, 0)
    console.expect_run(ct.run_conf)
    allow(OsCtld::Container::StopHandler).to receive(:schedule)

    console.send(:on_close)

    expect(OsCtld::Container::StopHandler).to have_received(:schedule).with(ct, ct.run_conf)
  end
end
