# frozen_string_literal: true

require 'osctld/run_state/start_config'

RSpec.describe OsCtld::RunState::StartConfig do
  it 'loads existing JSON config files' do
    with_tmpdir do |dir|
      path = File.join(dir, 'start.json')
      File.write(path, { 'booted' => true }.to_json)

      config = described_class.new(path)

      expect(config.exist?).to be(true)
      expect(config.send(:cfg)).to eq('booted' => true)
    end
  end

  it 'treats missing files as absent and removes existing files on close' do
    with_tmpdir do |dir|
      missing = described_class.new(File.join(dir, 'missing.json'))
      expect(missing.exist?).to be(false)

      path = File.join(dir, 'start.json')
      File.write(path, '{}')
      config = described_class.new(path)

      config.close

      expect(File.exist?(path)).to be(false)
      expect { missing.close }.not_to raise_error
    end
  end
end
