# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Event do
  def cmd(args: [], opts: {}, gopts: {})
    build_command(described_class, args:, opts:, gopts:)
  end

  let(:client) { FakeClientHelpers::ClientDouble.new(cmd_data: { event_subscribe: ['subscribed'] }) }

  it 'uses parsed pool:id values when checking current state' do
    command = cmd(args: %w[tank:ct1 running])
    allow(command).to receive(:osctld_open).and_return(client)
    allow(command).to receive(:monitor_loop)

    expect(command).to receive(:osctld_call).with(:ct_show, id: 'ct1', pool: 'tank').and_return(state: 'running')

    command.wait_ct

    expect(command).not_to have_received(:monitor_loop)
  end

  it 'uses the global pool when the id is not prefixed' do
    command = cmd(args: %w[ct1 running], gopts: { pool: 'tank' })
    allow(command).to receive(:osctld_open).and_return(client)
    allow(command).to receive(:monitor_loop)

    expect(command).to receive(:osctld_call).with(:ct_show, id: 'ct1', pool: 'tank').and_return(state: 'running')

    command.wait_ct
  end

  it 'subscribes with the parsed pool and id' do
    command = cmd(args: %w[tank:ct1 running])
    allow(command).to receive_messages(osctld_open: client, osctld_call: { state: 'stopped' })
    allow(command).to receive(:monitor_loop)

    command.wait_ct

    expect(client.calls).to include(
      [:cmd_data!, :event_subscribe, { type: 'state', opts: { id: 'ct1', pool: 'tank' } }]
    )
    expect(command).to have_received(:monitor_loop).with(client)
  end
end
