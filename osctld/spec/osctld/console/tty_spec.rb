# frozen_string_literal: true

require 'osctld/utils/switch_user'
require 'osctld/console'
require 'osctld/console/tty'
require 'osctld/container/lifecycle'
require 'osctld/container/run_configuration'

RSpec.describe OsCtld::Console::TTY do
  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  def build_ct(state: :running, lifecycle: nil)
    user = Struct.new(
      :ugid,
      :sysusername,
      :homedir
    ).new(1234, 'u-ct1', '/home/ct1')
    pool = Struct.new(:name).new('tank')
    Struct.new(
      :state,
      :entry_cgroup_path,
      :user,
      :pool,
      :id,
      :lifecycle,
      :run_conf,
      keyword_init: true
    ) do
      def get_past_run_conf
        nil
      end
    end.new(
      state:,
      entry_cgroup_path: '/osctl/pool.tank/ct.ct1',
      user:,
      pool:,
      id: 'ct1',
      lifecycle:
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

  it 'reaps the tty child before releasing lifecycle on mux failure' do
    lifecycle = instance_double(
      OsCtld::Container::Lifecycle,
      finish_process: false
    )
    tty = described_class.new(build_ct(lifecycle:), 1)
    input = instance_double(IO, close: nil)
    output = instance_double(IO, close: nil)
    tty.instance_variable_set(:@opened, true)
    tty.send(:tty_pid=, 1234)
    tty.send(:tty_in_io=, input)
    tty.send(:tty_out_io=, output)
    tty.send(:tty_run_id=, 'run-1')
    tty.send(:tty_process_id=, 'process-1')
    allow(IO).to receive(:select).and_raise(IOError, 'mux failed')
    call_order = []
    allow(Process).to receive(:wait) { call_order << :wait }
    allow(lifecycle).to receive(:finish_process) do
      call_order << :finish
      false
    end

    thread = tty.start
    thread.report_on_exception = false
    expect { thread.value }.to raise_error(IOError, 'mux failed')
    expect(input).to have_received(:close)
    expect(output).to have_received(:close)
    expect(Process).to have_received(:wait).with(1234)
    expect(lifecycle).to have_received(:finish_process)
      .with('run-1', 'process-1')
    expect(call_order).to eq(%i[wait finish])
    expect(tty.send(:tty_pid)).to be_nil
    expect(tty.send(:tty_process_id)).to be_nil
  end

  it 'clears tty state and invokes on_close when tty reads fail' do
    klass = Class.new(described_class) do
      attr_reader :closed

      def on_close(run_conf)
        @closed = run_conf
      end
    end
    tty = klass.new(build_ct, 1)
    io = instance_double(IO)
    run_conf = instance_double(OsCtld::Container::RunConfiguration)
    tty.instance_variable_set(:@opened, true)
    tty.send(:tty_pid=, 100)
    tty.send(:tty_in_io=, instance_double(IO, close: nil))
    tty.send(:tty_out_io=, io)
    tty.send(:tty_run_conf=, run_conf)
    allow(io).to receive(:read_nonblock).and_raise(IOError)
    allow(io).to receive(:close)

    expect(tty.send(:tty_read, io)).to be_nil
    expect(tty.instance_variable_get(:@opened)).to be(false)
    expect(tty.send(:tty_pid)).to be_nil
    expect(tty.send(:tty_in_io)).to be_nil
    expect(tty.send(:tty_out_io)).to be_nil
    expect(tty.send(:tty_run_conf)).to be_nil
    expect(tty.closed).to equal(run_conf)
  end

  it 'does not let stale tty EOF clear a replacement connection' do
    klass = Class.new(described_class) do
      attr_reader :closed

      def on_close(run_conf)
        @closed = run_conf
      end
    end
    tty = klass.new(build_ct, 1)
    stale_io = instance_double(IO)
    current_io = instance_double(IO)
    current_run_conf =
      instance_double(OsCtld::Container::RunConfiguration)
    tty.instance_variable_set(:@opened, true)
    tty.send(:tty_pid=, 200)
    tty.send(:tty_in_io=, current_io)
    tty.send(:tty_out_io=, current_io)
    tty.send(:tty_run_conf=, current_run_conf)
    allow(stale_io).to receive(:read_nonblock).and_raise(IOError)

    expect(tty.send(:tty_read, stale_io)).to be_nil
    expect(tty.instance_variable_get(:@opened)).to be(true)
    expect(tty.send(:tty_pid)).to eq(200)
    expect(tty.send(:tty_out_io)).to equal(current_io)
    expect(tty.send(:tty_run_conf)).to equal(current_run_conf)
    expect(tty.closed).to be_nil
  end

  it 'ignores writes through a stale input connection' do
    tty = described_class.new(build_ct, 1)
    stale_io = instance_double(IO)
    allow(stale_io).to receive(:write).and_raise(IOError)

    expect(tty.send(:tty_write, stale_io, 'input')).to be_nil
  end
end
