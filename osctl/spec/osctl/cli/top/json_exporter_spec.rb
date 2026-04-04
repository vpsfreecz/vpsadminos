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
    model = double('model', measure: nil, data: { ok: true })

    out, = capture_output do
      expect { described_class.new(model, 1).start }.to raise_error(Interrupt)
    end

    expect(Signal).to have_received(:trap).with('USR1')
    expect(JSON.parse(out)).to eq('ok' => true)
  end
end
