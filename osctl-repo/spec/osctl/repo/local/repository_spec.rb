# frozen_string_literal: true

require 'osctl/repo'

RSpec.describe OsCtl::Repo::Local::Repository do
  def read_index(path)
    JSON.parse(
      File.read(File.join(path, "v#{OsCtl::Repo::SCHEMA}", 'INDEX.json')),
      symbolize_names: true
    )
  end

  it 'creates the repository root and index' do
    with_tmpdir do |dir|
      repo = described_class.new(dir)

      expect(repo.exist?).to be(false)

      repo.create

      expect(repo.exist?).to be(true)
      expect(File).to exist(repo.path)
      expect(File).to exist(File.join(repo.path, 'INDEX.json'))
    end
  end

  it 'copies image files and creates tag symlinks when adding an image' do
    with_tmpdir do |dir|
      repo = described_class.new(dir)
      repo.create
      tar = write_fixture_file(dir, 'image.tar', 'tar-data')
      zfs = write_fixture_file(dir, 'image.zfs', 'zfs-data')

      repo.add(
        'vendor',
        'variant',
        'x86_64',
        'alpine',
        '3.20',
        tags: %w[stable current],
        image: { tar: tar, zfs: zfs }
      )

      expect(File.binread(File.join(repo.path, 'vendor/variant/x86_64/alpine/3.20/image-archive.tar')))
        .to eq('tar-data')
      expect(File.binread(File.join(repo.path, 'vendor/variant/x86_64/alpine/3.20/image-stream.tar')))
        .to eq('zfs-data')
      expect(File.readlink(File.join(repo.path, 'vendor/variant/x86_64/alpine/stable'))).to eq('3.20')
      expect(File.readlink(File.join(repo.path, 'vendor/variant/x86_64/alpine/current'))).to eq('3.20')
    end
  end

  it 'finds images by version and tag' do
    with_tmpdir do |dir|
      repo = described_class.new(dir)
      repo.create
      tar = write_fixture_file(dir, 'image.tar', 'tar-data')

      repo.add(
        'vendor',
        'variant',
        'x86_64',
        'alpine',
        '3.20',
        tags: %w[stable],
        image: { tar: tar }
      )

      expect(repo.find('vendor', 'variant', 'x86_64', 'alpine', '3.20').version).to eq('3.20')
      expect(repo.find('vendor', 'variant', 'x86_64', 'alpine', 'stable').version).to eq('3.20')
    end
  end

  it 'removes image files, tag symlinks, and empty parent directories' do
    with_tmpdir do |dir|
      repo = described_class.new(dir)
      repo.create
      tar = write_fixture_file(dir, 'image.tar', 'tar-data')

      repo.add(
        'vendor',
        'variant',
        'x86_64',
        'alpine',
        '3.20',
        tags: %w[stable],
        image: { tar: tar }
      )

      image = repo.find('vendor', 'variant', 'x86_64', 'alpine', '3.20')
      repo.remove(image)

      expect(repo.find('vendor', 'variant', 'x86_64', 'alpine', '3.20')).to be_nil
      expect(File).not_to exist(File.join(repo.path, 'vendor'))
      expect(File).not_to exist(File.join(repo.path, 'vendor/variant/x86_64/alpine/stable'))
    end
  end

  it 'creates the default vendor symlink and updates the index' do
    with_tmpdir do |dir|
      repo = described_class.new(dir)
      repo.create
      tar = write_fixture_file(dir, 'image.tar', 'tar-data')

      repo.add(
        'vendor',
        'variant',
        'x86_64',
        'alpine',
        '3.20',
        tags: [],
        image: { tar: tar }
      )
      repo.set_default_vendor('vendor')

      expect(File.readlink(File.join(repo.path, 'default'))).to eq('vendor')
      expect(read_index(dir)[:vendors][:default]).to eq('vendor')
    end
  end

  it 'creates the default variant symlink and updates the index' do
    with_tmpdir do |dir|
      repo = described_class.new(dir)
      repo.create
      tar = write_fixture_file(dir, 'image.tar', 'tar-data')

      repo.add(
        'vendor',
        'variant',
        'x86_64',
        'alpine',
        '3.20',
        tags: [],
        image: { tar: tar }
      )
      repo.set_default_variant('vendor', 'variant')

      expect(File.readlink(File.join(repo.path, 'vendor/default'))).to eq('variant')
      expect(read_index(dir)[:vendors][:vendor]).to eq('variant')
    end
  end

  it 'raises for missing default vendor targets' do
    with_tmpdir do |dir|
      repo = described_class.new(dir)
      repo.create

      expect do
        repo.set_default_vendor('missing')
      end.to raise_error(GLI::BadCommandLine, "vendor 'missing' not found")
    end
  end

  it 'raises for missing default variant targets' do
    with_tmpdir do |dir|
      repo = described_class.new(dir)
      repo.create
      FileUtils.mkdir_p(File.join(repo.path, 'vendor'))

      expect do
        repo.set_default_variant('vendor', 'missing')
      end.to raise_error(GLI::BadCommandLine, "variant 'missing' not found")
    end
  end

  it 'removes obsolete files and tags when replacing the same image version' do
    with_tmpdir do |dir|
      repo = described_class.new(dir)
      repo.create
      tar_v1 = write_fixture_file(dir, 'v1.tar', 'tar-v1')
      zfs_v1 = write_fixture_file(dir, 'v1.zfs', 'zfs-v1')

      repo.add(
        'vendor',
        'variant',
        'x86_64',
        'alpine',
        '3.20',
        tags: %w[current],
        image: { tar: tar_v1, zfs: zfs_v1 }
      )

      tar_v2 = write_fixture_file(dir, 'v2.tar', 'tar-v2')

      repo.add(
        'vendor',
        'variant',
        'x86_64',
        'alpine',
        '3.20',
        tags: %w[stable],
        image: { tar: tar_v2 }
      )

      expect(File).not_to exist(
        File.join(repo.path, 'vendor/variant/x86_64/alpine/3.20/image-stream.tar')
      )
      expect(File).not_to exist(File.join(repo.path, 'vendor/variant/x86_64/alpine/current'))
      expect(File.readlink(File.join(repo.path, 'vendor/variant/x86_64/alpine/stable'))).to eq(
        '3.20'
      )
      expect(File.binread(File.join(repo.path, 'vendor/variant/x86_64/alpine/3.20/image-archive.tar')))
        .to eq('tar-v2')
    end
  end
end
