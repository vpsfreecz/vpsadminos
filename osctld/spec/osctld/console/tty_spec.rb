# frozen_string_literal: true

require 'osctld/utils/switch_user'
require 'osctld/console'
require 'osctld/console/tty'

RSpec.describe OsCtld::Console::TTY do
  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  def build_ct(state: :running)
    user = Struct.new(:ugid).new(1234)
    pool = Struct.new(:name).new('tank')
    Struct.new(:state, :entry_cgroup_path, :user, :pool, :id, keyword_init: true).new(
      state:,
      entry_cgroup_path: '/osctl/pool.tank/ct.ct1',
      user:,
      pool:,
      id: 'ct1'
    )
  end

  it 'opens the tty when a running container gets its first client' do
    tty = described_class.new(build_ct, 1)
    client = instance_double(IO)
    allow(tty).to receive(:open)
    allow(tty).to receive(:wake)

    tty.add_client(client)

    expect(tty).to have_received(:open)
    expect(tty).to have_received(:wake)
  end

  it 'only wakes the worker when the tty is already open' do
    tty = described_class.new(build_ct, 1)
    tty.instance_variable_set(:@opened, true)
    allow(tty).to receive(:open)
    allow(tty).to receive(:wake)

    tty.add_client(instance_double(IO))

    expect(tty).not_to have_received(:open)
    expect(tty).to have_received(:wake)
  end

  it 'removes disconnected clients during client reads' do
    tty = described_class.new(build_ct, 1)
    client = instance_double(IO)
    tty.instance_variable_get(:@clients) << client
    allow(client).to receive(:read_nonblock).and_raise(IOError)

    expect(tty.send(:client_read, client)).to be_nil
    expect(tty.instance_variable_get(:@clients)).to be_empty
  end

  it 'wakes the thread with stop and joins it on close' do
    tty = described_class.new(build_ct, 1)
    thread = instance_double(Thread, join: nil)
    tty.instance_variable_set(:@thread, thread)
    allow(tty).to receive(:wake)

    tty.close

    expect(tty).to have_received(:wake).with(:stop)
    expect(thread).to have_received(:join)
  end

  it 'clears tty state and invokes on_close when tty reads fail' do
    klass = Class.new(described_class) do
      attr_reader :closed

      def on_close
        @closed = true
      end
    end
    tty = klass.new(build_ct, 1)
    io = instance_double(IO)
    tty.instance_variable_set(:@opened, true)
    tty.send(:tty_pid=, 100)
    tty.send(:tty_in_io=, instance_double(IO))
    tty.send(:tty_out_io=, io)
    allow(io).to receive(:read_nonblock).and_raise(IOError)

    expect(tty.send(:tty_read, io)).to be_nil
    expect(tty.instance_variable_get(:@opened)).to be(false)
    expect(tty.send(:tty_pid)).to be_nil
    expect(tty.send(:tty_in_io)).to be_nil
    expect(tty.send(:tty_out_io)).to be_nil
    expect(tty.closed).to be(true)
  end
end
