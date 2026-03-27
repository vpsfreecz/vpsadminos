# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/command'
require 'osctld/commands/base'
require 'osctld/eventd'
require 'osctld/commands/event/broadcast'

RSpec.describe OsCtld::Commands::Event::Broadcast do
  it 'rejects missing events' do
    cmd = described_class.new({}, { id: 1 })

    expect do
      cmd.execute
    end.to raise_error(OsCtld::CommandFailed, /missing events/)
  end

  it 'rejects non-string event types' do
    cmd = described_class.new({ events: [{ type: :state, opts: {} }] }, { id: 1 })

    expect do
      cmd.execute
    end.to raise_error(OsCtld::CommandFailed, 'type must be a string')
  end

  it 'rejects non-hash opts' do
    cmd = described_class.new({ events: [{ type: 'state', opts: 'bad' }] }, { id: 1 })

    expect do
      cmd.execute
    end.to raise_error(OsCtld::CommandFailed, 'opts must be a hash')
  end

  it 'broadcasts all provided events in order' do
    allow(OsCtld::Eventd).to receive(:broadcast)

    cmd = described_class.new(
      {
        events: [
          { type: 'state', opts: { pool: 'tank', id: 'ct1' } },
          { type: 'db', opts: { action: 'add' } }
        ]
      },
      { id: 1 }
    )

    expect(cmd.execute).to eq(status: true, output: nil)
    expect(OsCtld::Eventd).to have_received(:broadcast).with('state', pool: 'tank', id: 'ct1').ordered
    expect(OsCtld::Eventd).to have_received(:broadcast).with('db', action: 'add').ordered
  end
end
