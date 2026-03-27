# frozen_string_literal: true

require 'osctld/auto_start/state'

RSpec.describe OsCtld::AutoStart::State do
  def build_pool(dir)
    Struct.new(:autostart_dir).new(dir)
  end

  def ct(id)
    Struct.new(:id).new(id)
  end

  it 'loads started containers from the state file' do
    with_tmpdir do |dir|
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, 'started-cts.txt'), "ct1\nct2\n")

      state = described_class.load(build_pool(dir))

      expect(state.is_started?(ct('ct1'))).to be(true)
      expect(state.is_started?(ct('ct2'))).to be(true)
      expect(state.is_started?(ct('ct3'))).to be(false)
    end
  end

  it 'declares the state file asset' do
    with_tmpdir do |dir|
      assets = Struct.new(:files) do
        def file(path, **opts)
          files << { path:, **opts }
        end
      end.new([])

      described_class.new(build_pool(dir)).assets(assets)

      expect(assets.files).to contain_exactly(
        include(
          path: File.join(dir, 'started-cts.txt'),
          desc: 'Contains a list of auto-started containers',
          user: 0,
          group: 0,
          mode: 0o600,
          optional: true
        )
      )
    end
  end

  it 'deduplicates started containers and rewrites the file' do
    with_tmpdir do |dir|
      FileUtils.mkdir_p(dir)
      state = described_class.new(build_pool(dir))

      state.set_started(ct('ct1'))
      state.set_started(ct('ct1'))
      state.set_started(ct('ct2'))

      expect(File.readlines(File.join(dir, 'started-cts.txt'), chomp: true)).to eq(%w[ct1 ct2])
      expect(state.is_started?(ct('ct1'))).to be(true)
      expect(state.is_started?(ct('ct2'))).to be(true)
    end
  end

  it 'clears only the requested container from the state file' do
    with_tmpdir do |dir|
      FileUtils.mkdir_p(dir)
      state = described_class.new(build_pool(dir))
      state.set_started(ct('ct1'))
      state.set_started(ct('ct2'))

      state.clear(ct('ct1'))

      expect(File.readlines(File.join(dir, 'started-cts.txt'), chomp: true)).to eq(['ct2'])
      expect(state.is_started?(ct('ct1'))).to be(false)
      expect(state.is_started?(ct('ct2'))).to be(true)
    end
  end

  it 'ignores a missing state file' do
    with_tmpdir do |dir|
      FileUtils.mkdir_p(dir)

      expect { described_class.load(build_pool(dir)) }.not_to raise_error
    end
  end
end
