# frozen_string_literal: true

require 'osctld/eventd/event'

RSpec.describe OsCtld::Eventd::Event do
  it 'keeps the event type and opts unchanged' do
    opts = { id: 'ct1', runtime_state: :running }
    event = described_class.new(:runtime_state, opts)

    expect(event.type).to eq(:runtime_state)
    expect(event.opts).to be(opts)
  end
end
