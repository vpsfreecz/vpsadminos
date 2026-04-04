# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Bisect do
  let(:cts) do
    [
      { pool: 'tank', id: 'ct1' },
      { pool: 'tank', id: 'ct2' }
    ]
  end

  it 'accepts explicit confirmation and rejects anything else' do
    with_stdin("y\n") do
      expect { described_class.new(cts, suspend_action: :freeze, cols: %i[id]).send(:ask_confirmation!) }.not_to raise_error
    end

    with_stdin("n\n") do
      expect do
        described_class.new(cts, suspend_action: :freeze, cols: %i[id]).send(:ask_confirmation!)
      end.to raise_error('Aborted')
    end
  end

  it 'toggles ask_success? based on previous state' do
    bisect = described_class.new(cts, suspend_action: :freeze, cols: %i[id])

    with_stdin("y\nn\n") do
      expect(bisect.send(:ask_success?)).to be(false)
      expect(bisect.send(:ask_success?)).to be(true)
    end
  end

  it 'resets by resuming all selected containers' do
    bisect = described_class.new(cts, suspend_action: :freeze, cols: %i[id])

    expect(bisect).to receive(:execute_action_set).with(cts, :resume)

    bisect.reset
  end

  it 'maps freeze actions to freeze and thaw commands' do
    client = FakeClientHelpers::ClientDouble.new(
      cmd_responses: {
        ct_freeze: [client_response(status: true, response: {})],
        ct_unfreeze: [client_response(status: true, response: {})]
      }
    )
    allow(Etc).to receive(:nprocessors).and_return(1)
    stub_osctld_client(client)
    bisect = described_class.new(cts.first(1), suspend_action: :freeze, cols: %i[id])

    bisect.send(:execute_action_set, cts.first(1), :suspend)
    bisect.send(:execute_action_set, cts.first(1), :resume)

    expect(client.calls).to include(
      [:cmd_response, :ct_freeze, { pool: 'tank', id: 'ct1' }],
      [:cmd_response, :ct_unfreeze, { pool: 'tank', id: 'ct1' }]
    )
  end

  it 'maps stop actions to stop and start commands' do
    client = FakeClientHelpers::ClientDouble.new(
      cmd_responses: {
        ct_stop: [client_response(status: true, response: {})],
        ct_start: [client_response(status: true, response: {})]
      }
    )
    allow(Etc).to receive(:nprocessors).and_return(1)
    stub_osctld_client(client)
    bisect = described_class.new(cts.first(1), suspend_action: :stop, cols: %i[id])

    bisect.send(:execute_action_set, cts.first(1), :suspend)
    bisect.send(:execute_action_set, cts.first(1), :resume)

    expect(client.calls).to include(
      [:cmd_response, :ct_stop, { pool: 'tank', id: 'ct1' }],
      [:cmd_response, :ct_start, { pool: 'tank', id: 'ct1' }]
    )
  end

  it 'resumes all affected containers when run aborts with an error' do
    bisect = described_class.new(cts, suspend_action: :freeze, cols: %i[id])
    allow(bisect).to receive(:print_set)
    allow(bisect).to receive(:ask_confirmation!)
    allow(bisect).to receive(:bisect).and_raise(StandardError, 'boom')

    expect(bisect).to receive(:reset)

    expect { bisect.run }.to raise_error(StandardError, 'boom')
  end
end
