# frozen_string_literal: true

require 'osctld/upgrade_handoff'

RSpec.describe OsCtld::UpgradeHandoff do
  let(:ct) do
    Struct.new(:pool, :id).new(Struct.new(:name).new('tank'), '101')
  end

  it 'loads desired containers only for the current boot' do
    with_tmpdir do |root|
      path = File.join(root, 'handoff.yml')
      boot_id_path = File.join(root, 'boot-id')
      File.write(boot_id_path, "boot-1\n")
      File.write(
        path,
        YAML.dump(
          'schema' => 1,
          'boot_id' => 'boot-1',
          'created_at' => 1.0,
          'containers' => [
            {
              'pool' => 'tank',
              'id' => '101',
              'source' => 'legacy-runtime-upgrade',
              'priority' => 17
            }
          ],
          'runtime_containers' => [
            {
              'pool' => 'tank',
              'id' => '101',
              'source' => 'legacy-runtime-upgrade'
            }
          ]
        )
      )

      handoff = described_class.load(path, boot_id_path:)

      expect(handoff.include?(ct)).to be(true)
      expect(handoff.runtime?(ct)).to be(true)
      expect(handoff.empty?).to be(false)
    end
  end

  it 'rejects malformed provenance and priority fields' do
    with_tmpdir do |root|
      path = File.join(root, 'handoff.yml')
      boot_id_path = File.join(root, 'boot-id')
      File.write(boot_id_path, "boot-1\n")
      File.write(
        path,
        YAML.dump(
          'schema' => 1,
          'boot_id' => 'boot-1',
          'created_at' => 1.0,
          'containers' => [
            {
              'pool' => 'tank',
              'id' => '101',
              'source' => 'other',
              'priority' => '17'
            }
          ],
          'runtime_containers' => []
        )
      )

      handoff = described_class.load(path, boot_id_path:)

      expect(handoff).not_to be_valid
      expect(handoff.error).to match(/containers\[0\] is invalid/)
    end
  end

  it 'rejects conflicting duplicate desired entries' do
    with_tmpdir do |root|
      path = File.join(root, 'handoff.yml')
      boot_id_path = File.join(root, 'boot-id')
      File.write(boot_id_path, "boot-1\n")
      File.write(
        path,
        YAML.dump(
          'schema' => 1,
          'boot_id' => 'boot-1',
          'created_at' => 1.0,
          'containers' => [
            {
              'pool' => 'tank',
              'id' => '101',
              'source' => 'legacy-runtime-upgrade',
              'priority' => 17
            },
            {
              'pool' => 'tank',
              'id' => '101',
              'source' => 'legacy-runtime-upgrade',
              'priority' => 18
            }
          ],
          'runtime_containers' => []
        )
      )

      handoff = described_class.load(path, boot_id_path:)

      expect(handoff).not_to be_valid
      expect(handoff.error).to match(/conflicts with an earlier entry/)
    end
  end

  it 'ignores a handoff left by another boot' do
    with_tmpdir do |root|
      path = File.join(root, 'handoff.yml')
      boot_id_path = File.join(root, 'boot-id')
      File.write(boot_id_path, "boot-2\n")
      File.write(
        path,
        YAML.dump(
          'schema' => 1,
          'boot_id' => 'boot-1',
          'containers' => [{ 'pool' => 'tank', 'id' => '101' }],
          'runtime_containers' => []
        )
      )

      expect(described_class.load(path, boot_id_path:)).to be_empty
    end
  end

  it 'rejects an unsupported handoff schema from the current boot' do
    with_tmpdir do |root|
      path = File.join(root, 'handoff.yml')
      boot_id_path = File.join(root, 'boot-id')
      File.write(boot_id_path, "boot-1\n")
      File.write(
        path,
        YAML.dump(
          'schema' => 2,
          'boot_id' => 'boot-1',
          'containers' => [{ 'pool' => 'tank', 'id' => '101' }]
        )
      )

      handoff = described_class.load(path, boot_id_path:)

      expect(handoff).not_to be_valid
      expect(handoff.error).to match(/unsupported schema/)
      expect(handoff.complete).to be(false)
      expect(File).to exist(path)
    end
  end

  it 'rejects malformed current state without deleting it' do
    with_tmpdir do |root|
      path = File.join(root, 'handoff.yml')
      boot_id_path = File.join(root, 'boot-id')
      File.write(boot_id_path, "boot-1\n")
      File.write(path, "boot_id: boot-1\ncontainers: [\n")

      handoff = described_class.load(path, boot_id_path:)

      expect(handoff).not_to be_valid
      expect(handoff.error).to match(/invalid YAML/)
      expect(handoff.complete).to be(false)
      expect(File).to exist(path)
    end
  end

  it 'ignores an unsupported handoff from another boot' do
    with_tmpdir do |root|
      path = File.join(root, 'handoff.yml')
      boot_id_path = File.join(root, 'boot-id')
      File.write(boot_id_path, "boot-2\n")
      File.write(
        path,
        YAML.dump(
          'schema' => 2,
          'boot_id' => 'boot-1',
          'containers' => 'unsupported'
        )
      )

      expect(described_class.load(path, boot_id_path:)).to be_empty
    end
  end

  it 'removes the handoff only when persistence is complete' do
    with_tmpdir do |root|
      path = File.join(root, 'handoff.yml')
      File.write(path, '{}')

      described_class.new(path, [], []).complete

      expect(File).not_to exist(path)
    end
  end

  it 'retains unfulfilled entries for a later daemon attempt' do
    with_tmpdir do |root|
      path = File.join(root, 'handoff.yml')
      File.write(path, '{}')
      handoff = described_class.new(path, [%w[tank 101]], [%w[tank 101]])

      expect(handoff.complete).to be(false)
      expect(File).to exist(path)
      expect(handoff.remaining).to eq([%w[tank 101]])

      handoff.fulfil(ct)

      expect(handoff.complete).to be(false)
      expect(File).to exist(path)

      handoff.fulfil_runtime(ct)

      expect(handoff.complete).to be(true)
      expect(File).not_to exist(path)
    end
  end
end
