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
    allow(OsCtl::Lib::Queue).to receive(:new).and_return(queue)
    allow(Signal).to receive(:trap)
    model = double('model', measure: nil, json_data: { ok: true })

    out, = capture_output do
      expect { described_class.new(model, 1).start }.to raise_error(Interrupt)
    end

    expect(Signal).to have_received(:trap).with('USR1')
    expect(JSON.parse(out)).to eq('ok' => true)
  end

  it 'takes one new acquisition when USR1 wakes the queue' do
    queue = instance_double(OsCtl::Lib::Queue, clear: nil)
    allow(OsCtl::Lib::Queue).to receive(:new).and_return(queue)
    handler = nil
    allow(Signal).to receive(:trap).with('USR1') { |_, &block| handler = block }
    allow(Thread).to receive(:new).and_yield
    allow(queue).to receive(:<<).with(nil)
    calls = 0
    allow(queue).to receive(:pop).with(timeout: 15) do
      calls += 1
      raise Interrupt if calls > 2

      handler.call if calls == 2
    end
    frame = { top_schema: 2, sequence: 2 }
    model = instance_double(OsCtl::Cli::Top::PartialModel, measure: nil)
    allow(model).to receive(:json_data).and_return(frame, frame.merge(sequence: 3))
    out, = capture_output do
      expect { described_class.new(model, 15).start }.to raise_error(Interrupt)
    end
    expect(model).to have_received(:measure).twice
    expect(queue).to have_received(:<<).with(nil).once
    expect(out.lines.map { |line| JSON.parse(line) }).to eq(
      [{ 'top_schema' => 2, 'sequence' => 2 }, { 'top_schema' => 2, 'sequence' => 3 }]
    )
  end
end
