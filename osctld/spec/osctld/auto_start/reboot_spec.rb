# frozen_string_literal: true

require 'osctld/auto_start/reboot'

RSpec.describe OsCtld::AutoStart::Reboot do
  def build_pool(dir)
    Struct.new(:autostart_dir).new(dir)
  end

  def ct(id)
    Struct.new(:id).new(id)
  end

  it 'loads reboot requests from the state file' do
    with_tmpdir do |dir|
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, 'reboot-cts.txt'), "ct1\nct2\n")

      reboot = described_class.load(build_pool(dir))

      expect(reboot.include?(ct('ct1'))).to be(true)
      expect(reboot.include?(ct('ct2'))).to be(true)
      expect(reboot.include?(ct('ct3'))).to be(false)
    end
  end

  it 'declares the reboot file asset' do
    with_tmpdir do |dir|
      assets = Struct.new(:files) do
        def file(path, **opts)
          files << { path:, **opts }
        end
      end.new([])

      described_class.new(build_pool(dir)).assets(assets)

      expect(assets.files).to contain_exactly(
        include(
          path: File.join(dir, 'reboot-cts.txt'),
          desc: 'Contains a list of containers to reboot',
          user: 0,
          group: 0,
          mode: 0o600,
          optional: true
        )
      )
    end
  end

  it 'deduplicates entries and rewrites the file' do
    with_tmpdir do |dir|
      FileUtils.mkdir_p(dir)
      reboot = described_class.new(build_pool(dir))

      reboot.add(ct('ct1'))
      reboot.add(ct('ct1'))
      reboot.add(ct('ct2'))

      expect(File.readlines(File.join(dir, 'reboot-cts.txt'), chomp: true)).to eq(%w[ct1 ct2])
    end
  end

  it 'clears only the selected reboot request' do
    with_tmpdir do |dir|
      FileUtils.mkdir_p(dir)
      reboot = described_class.new(build_pool(dir))
      reboot.add(ct('ct1'))
      reboot.add(ct('ct2'))

      reboot.clear(ct('ct1'))

      expect(reboot.include?(ct('ct1'))).to be(false)
      expect(reboot.include?(ct('ct2'))).to be(true)
      expect(File.readlines(File.join(dir, 'reboot-cts.txt'), chomp: true)).to eq(['ct2'])
    end
  end

  it 'clears all reboot requests' do
    with_tmpdir do |dir|
      FileUtils.mkdir_p(dir)
      reboot = described_class.new(build_pool(dir))
      reboot.add(ct('ct1'))
      reboot.add(ct('ct2'))

      reboot.clear_all

      expect(reboot.include?(ct('ct1'))).to be(false)
      expect(reboot.include?(ct('ct2'))).to be(false)
      expect(File.read(File.join(dir, 'reboot-cts.txt'))).to eq('')
    end
  end

  it 'ignores a missing state file' do
    with_tmpdir do |dir|
      FileUtils.mkdir_p(dir)

      expect { described_class.load(build_pool(dir)) }.not_to raise_error
    end
  end
end
