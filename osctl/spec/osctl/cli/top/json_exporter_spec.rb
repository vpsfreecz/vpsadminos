# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Top::JsonExporter do
  it 'exports one json iteration and installs the signal trap' do
    queue = instance_double(OsCtl::Lib::Queue, clear: nil)
    count = 0
    allow(queue).to receive(:pop).with(timeout: 1) do
      count += 1
      raise Interrupt if count > 1

      nil
    end
    allow(Signal).to receive(:trap).with('USR1').and_return('DEFAULT')
    allow(Signal).to receive(:trap).with('USR1', 'DEFAULT')
    frame = { complete: false, invalid_reason: 'inventory_pending' }
    model = instance_double(
      OsCtl::Cli::Top::PartialModel, sample_wakeup: queue, check_monitor!: nil, measure: nil, json_data: frame
    )

    out, = capture_output do
      expect { described_class.new(model, 1).start }.to raise_error(Interrupt)
    end

    expect(Signal).to have_received(:trap).with('USR1', 'DEFAULT')
    expect(JSON.parse(out)).to eq('complete' => false, 'invalid_reason' => 'inventory_pending')
  end

  it 'takes one new acquisition when USR1 wakes the queue' do
    queue = instance_double(OsCtl::Lib::Queue, clear: nil)
    handler = nil
    allow(Signal).to receive(:trap).with('USR1') do |_, &block|
      handler = block
      'DEFAULT'
    end
    allow(Signal).to receive(:trap).with('USR1', 'DEFAULT')
    allow(Thread).to receive(:new).and_yield
    allow(queue).to receive(:<<).with(:refresh)
    calls = 0
    allow(queue).to receive(:pop).with(timeout: 15) do
      calls += 1
      raise Interrupt if calls > 2

      handler.call if calls == 2
    end
    frame = { top_schema: 2, sequence: 2 }
    model = instance_double(OsCtl::Cli::Top::PartialModel, sample_wakeup: queue, check_monitor!: nil, measure: nil)
    allow(model).to receive(:json_data).and_return(frame, frame.merge(sequence: 3))
    out, = capture_output do
      expect { described_class.new(model, 15).start }.to raise_error(Interrupt)
    end
    expect(model).to have_received(:measure).twice
    expect(queue).to have_received(:<<).with(:refresh).once
    expect(out.lines.map { |line| JSON.parse(line) }).to eq(
      [{ 'top_schema' => 2, 'sequence' => 2 }, { 'top_schema' => 2, 'sequence' => 3 }]
    )
  end

  it 'does not wait for the rate or measure when subscription already failed' do
    queue = instance_double(OsCtl::Lib::Queue)
    model = instance_double(OsCtl::Cli::Top::PartialModel, sample_wakeup: queue)
    allow(model).to receive(:check_monitor!).and_raise(OsCtl::Cli::Top::PartialModel::MonitorLost)
    allow(Signal).to receive(:trap)

    out, err = capture_output do
      expect { described_class.new(model, 3600).start }.to raise_error(OsCtl::Cli::Top::PartialModel::MonitorLost)
    end

    expect([out, err]).to eq(['', ''])
  end

  it 'wakes an idle JSON wait on permanent loss and keeps the first reason' do
    monitor = instance_double(OsCtl::Cli::Top::Monitor, subscribe: nil, stop: nil)
    allow(OsCtl::Cli::Top::Monitor).to receive(:new).and_return(monitor)
    allow(monitor).to receive(:with_lookup).and_yield
    stub_osctld_client(FakeClientHelpers::ClientDouble.new(cmd_data: { ct_list: [[]] }))
    model = OsCtl::Cli::Top::PartialModel.new(enable_netif: false, enable_zfs: false)
    expect { model.check_monitor! }.not_to raise_error
    queue = model.sample_wakeup
    waiting = Queue.new
    consumer = Thread.new do
      waiting << true
      queue.pop(timeout: 3600)
    end
    expect(waiting.pop(timeout: 2)).to be(true)

    model.monitor_unavailable(startup: true)
    model.monitor_ready
    model.monitor_unavailable

    expect(consumer.join(2)).to eq(consumer)
    expect(consumer.value).to eq(:monitor_loss)
    expect(queue).to be_empty
    expect { model.check_monitor! }.to raise_error(OsCtl::Cli::Top::PartialModel::MonitorLost, /unable to subscribe/)
  ensure
    consumer&.kill
    consumer&.join
    model&.stop
  end

  it 'checks for loss after waking and before publishing an in-flight measurement' do
    queue = instance_double(OsCtl::Lib::Queue, clear: nil)
    allow(queue).to receive(:pop).with(timeout: 3600)
    allow(Signal).to receive(:trap)
    model = instance_double(OsCtl::Cli::Top::PartialModel, sample_wakeup: queue, json_data: { complete: true })
    lost = false
    allow(model).to receive(:check_monitor!) do
      raise OsCtl::Cli::Top::PartialModel::MonitorLost if lost
    end
    allow(model).to receive(:measure) { lost = true }

    out, = capture_output do
      expect { described_class.new(model, 3600).start }.to raise_error(OsCtl::Cli::Top::PartialModel::MonitorLost)
    end

    expect(out).to be_empty
    expect(model).to have_received(:measure).once
  end
end
