# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/command'
require 'osctld/commands/base'
require 'osctld/eventd'
require 'osctld/eventd/event'
require 'osctld/commands/event/subscribe'

RSpec.describe OsCtld::Commands::Event::Subscribe do
  let(:event) do
    OsCtld::Eventd::Event.new(
      :runtime_state,
      pool: 'tank',
      id: 'ct1',
      runtime_state: 'running'
    )
  end

  let(:command_class) do
    Class.new(described_class) do
      def log(*); end
    end
  end

  def build_queue
    queue_class = Class.new do
      def pop(timeout: nil); end
    end

    instance_double(queue_class)
  end

  def build_handler
    handler_class = Class.new do
      def socket; end

      def reply_ok(_value); end
    end

    instance_double(handler_class, socket: nil)
  end

  it 'accepts events when no filters are specified' do
    cmd = described_class.new({}, { id: 1 })

    expect(cmd.send(:filter?, event)).to be(true)
  end

  it 'matches a single type filter' do
    cmd = described_class.new({ type: 'runtime_state' }, { id: 1 })

    expect(cmd.send(:filter?, event)).to be(true)
  end

  it 'rejects non-matching single type filters' do
    cmd = described_class.new({ type: 'db' }, { id: 1 })

    expect(cmd.send(:filter?, event)).to be(false)
  end

  it 'matches only requested types when type filter is an array' do
    cmd = described_class.new({ type: %w[runtime_state db] }, { id: 1 })

    expect(cmd.send(:filter?, event)).to be(true)
    expect(
      cmd.send(:filter?, OsCtld::Eventd::Event.new(:ct_exit, pool: 'tank', id: 'ct1'))
    ).to be(false)
  end

  it 'supports symbol arrays in type filters' do
    cmd = described_class.new({ type: %i[runtime_state db] }, { id: 1 })

    expect(cmd.send(:filter?, event)).to be(true)
    expect(
      cmd.send(:filter?, OsCtld::Eventd::Event.new(:ct_exit, pool: 'tank', id: 'ct1'))
    ).to be(false)
  end

  it 'filters by scalar event options' do
    cmd = described_class.new({ opts: { pool: 'tank', id: 'ct1' } }, { id: 1 })

    expect(cmd.send(:filter?, event)).to be(true)
    expect(
      cmd.send(
        :filter?,
        OsCtld::Eventd::Event.new(
          :runtime_state,
          pool: 'other',
          id: 'ct1',
          runtime_state: 'running'
        )
      )
    ).to be(false)
  end

  it 'filters by array-valued event options' do
    cmd = described_class.new(
      { opts: { runtime_state: %w[running starting] } },
      { id: 1 }
    )

    expect(cmd.send(:filter?, event)).to be(true)
    expect(
      cmd.send(
        :filter?,
        OsCtld::Eventd::Event.new(
          :runtime_state,
          pool: 'tank',
          id: 'ct1',
          runtime_state: 'stopped'
        )
      )
    ).to be(false)
  end

  it 'acknowledges the subscription and forwards matching events' do
    queue = build_queue
    handler = build_handler

    allow(OsCtld::Eventd).to receive(:subscribe).and_return(queue)
    allow(OsCtld::Eventd).to receive(:unsubscribe)
    allow(queue).to receive(:pop).with(timeout: 0.2).and_return(event)
    allow(handler).to receive(:reply_ok).and_return(true)
    allow(handler).to receive(:reply_ok).with('subscribed').and_return(true)
    allow(handler).to receive(:reply_ok).with(
      {
        type: :runtime_state,
        opts: { pool: 'tank', id: 'ct1', runtime_state: 'running' }
      }
    ).and_return(false)

    cmd = command_class.new({ type: 'runtime_state' }, { id: 1, handler: })
    ret = cmd.execute

    expect(ret).to eq(status: true, output: nil)
    expect(OsCtld::Eventd).to have_received(:unsubscribe).with(queue)
  end

  it 'skips non-matching events while continuing the stream' do
    queue = build_queue
    handler = build_handler
    non_matching = OsCtld::Eventd::Event.new(:db, pool: 'tank', id: 'ct1')

    allow(OsCtld::Eventd).to receive(:subscribe).and_return(queue)
    allow(OsCtld::Eventd).to receive(:unsubscribe)
    allow(queue).to receive(:pop).with(timeout: 0.2).and_return(non_matching, event)
    allow(handler).to receive(:reply_ok).and_return(true)
    allow(handler).to receive(:reply_ok).with('subscribed').and_return(true)
    allow(handler).to receive(:reply_ok).with(
      {
        type: :runtime_state,
        opts: { pool: 'tank', id: 'ct1', runtime_state: 'running' }
      }
    ).and_return(false)

    cmd = command_class.new({ type: 'runtime_state' }, { id: 1, handler: })
    ret = cmd.execute

    expect(ret).to eq(status: true, output: nil)
    expect(OsCtld::Eventd).to have_received(:unsubscribe).with(queue)
    expect(handler).not_to have_received(:reply_ok).with(
      { type: :db, opts: { pool: 'tank', id: 'ct1' } }
    )
  end

  it 'sends a shutdown event before returning a shutdown error when stop is requested' do
    queue = build_queue
    handler = build_handler

    allow(OsCtld::Eventd).to receive(:subscribe).and_return(queue)
    allow(OsCtld::Eventd).to receive(:unsubscribe)
    allow(queue).to receive(:pop)
    allow(handler).to receive(:reply_ok).and_return(true)
    allow(handler).to receive(:reply_ok).with('subscribed').and_return(true)

    cmd = command_class.new({}, { id: 1, handler: })
    cmd.request_stop

    ret = cmd.execute

    expect(ret).to eq(status: false, message: 'osctld is shutting down')
    expect(handler).to have_received(:reply_ok).with(
      {
        type: :osctld_shutdown,
        opts: {}
      }
    ).once
    expect(queue).not_to have_received(:pop)
    expect(OsCtld::Eventd).to have_received(:unsubscribe).with(queue).once
  end

  it 'does not send the shutdown event when filters reject it' do
    queue = build_queue
    handler = build_handler

    allow(OsCtld::Eventd).to receive(:subscribe).and_return(queue)
    allow(OsCtld::Eventd).to receive(:unsubscribe)
    allow(queue).to receive(:pop)
    allow(handler).to receive(:reply_ok).and_return(true)
    allow(handler).to receive(:reply_ok).with('subscribed').and_return(true)

    cmd = command_class.new({ type: 'runtime_state' }, { id: 1, handler: })
    cmd.request_stop

    ret = cmd.execute

    expect(ret).to eq(status: false, message: 'osctld is shutting down')
    expect(handler).not_to have_received(:reply_ok).with(
      {
        type: :osctld_shutdown,
        opts: {}
      }
    )
    expect(queue).not_to have_received(:pop)
    expect(OsCtld::Eventd).to have_received(:unsubscribe).with(queue).once
  end
end
