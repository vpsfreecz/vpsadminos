# frozen_string_literal: true

module OsCtld
  module ContainerControl
    module Utils; end
  end
end

require 'osctld/container_control/utils/runscript'

RSpec.describe OsCtld::ContainerControl::Utils::Runscript::Runner do
  subject(:runner) { runner_class.new(lifecycle_start_token) }

  let(:runner_class) do
    Class.new do
      include OsCtld::ContainerControl::Utils::Runscript::Runner

      attr_reader :pool, :ctid, :run_id, :lifecycle_start_token

      def initialize(lifecycle_start_token)
        @pool = 'tank'
        @ctid = 'ct1'
        @run_id = 'run-1'
        @lifecycle_start_token = lifecycle_start_token
      end
    end
  end
  let(:lifecycle_start_token) { 'start-token' }
  let(:socket) do
    instance_double(
      UNIXSocket,
      send: nil,
      readline: "{\"status\":true}\n",
      close: nil
    )
  end
  let(:sent_payloads) { [] }

  before do
    allow(UNIXSocket).to receive(:new).and_return(socket)
    allow(socket).to receive(:send) { |payload, _flags| sent_payloads << payload }
  end

  it 'sends the transient capability through the wrapper callback' do
    runner.send(:osctld_wrapper_callback)

    payload = JSON.parse(sent_payloads.fetch(0), symbolize_names: true)
    expect(payload).to eq(
      cmd: 'ct_wrapper_start',
      opts: {
        id: 'ct1',
        pool: 'tank',
        run_id: 'run-1',
        lifecycle_start_token: 'start-token'
      }
    )
  end

  it 'rejects a missing transient capability before opening a socket' do
    runner = runner_class.new(nil)

    expect do
      runner.send(:osctld_wrapper_callback)
    end.to raise_error(RuntimeError, 'missing transient lifecycle start capability')
    expect(UNIXSocket).not_to have_received(:new)
  end
end
