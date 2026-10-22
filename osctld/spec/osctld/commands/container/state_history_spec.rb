# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/command'
require 'osctld/commands/container/state_history'

RSpec.describe OsCtld::Commands::Container::StateHistory do
  it 'queries timeline or compact views with optional persisted-identity filters' do
    data = { schema_version: 1, boot_id: 'boot', available: false, reason: 'state_missing', entries: [] }
    allow(OsCtld::ContainerStateHistory).to receive(:export).with(view: 'timeline', pool: nil, id: nil).and_return(data)
    allow(OsCtld::ContainerStateHistory).to receive(:export).with(view: 'ever_running', pool: 'tank', id: '_ct').and_return(data)

    expect(described_class.run).to eq(status: true, output: data)
    expect(described_class.run(view: 'ever_running', pool: 'tank', id: '_ct')).to eq(status: true, output: data)
  end

  [{ bad: true }, { view: 'bad' }, { id: 'ct1' }, { pool: false }, { pool: 'tank', id: false }, { pool: '../tank' }, { pool: 'tank', id: 'ct.id' }].each do |opts|
    it "rejects unsupported request #{opts.inspect}" do
      expect { described_class.run(**opts) }.to raise_error(OsCtld::CommandFailed)
    end
  end

  it 'records, reloads and queries the supported generic ID grammar' do
    with_tmpdir do |dir|
      path = File.join(dir, 'container-state-history.json')
      boot_id_path = File.join(dir, 'boot-id')
      boot_id = '00000000-0000-4000-8000-000000000001'
      File.write(boot_id_path, boot_id)
      File.write(path, JSON.generate(schema_version: 1, boot_id:, next_sequence: 1, dropped_events: 0, entries: [], events: []))
      history = OsCtld::ContainerStateHistory.new(path:, boot_id_path:)
      history.load
      ids = ['_ct', '-ct', 'MiXeD_01', 'a' * 100]
      ids.each { |id| expect(history.record('tank', id, :running)).to be(true) }
      restarted = OsCtld::ContainerStateHistory.new(path:, boot_id_path:)
      restarted.load
      allow(OsCtld::ContainerStateHistory).to receive(:instance).and_return(restarted)
      result = described_class.run(view: 'ever_running')

      expect(result[:status]).to be(true)
      expect(result[:output]).to include(schema_version: 1, boot_id:, available: true, reason: nil)
      expect(result[:output][:entries].map { |entry| entry[:id] }).to eq(ids.sort)
      expect(File).not_to exist(File.join(dir, 'container-state-history.failed.json'))
    end
  end
end
