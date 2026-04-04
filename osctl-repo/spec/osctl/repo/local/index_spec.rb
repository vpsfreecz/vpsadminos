# frozen_string_literal: true

require 'osctl/repo'

RSpec.describe OsCtl::Repo::Local::Index do
  def build_repo(dir)
    Struct.new(:path, keyword_init: true).new(
      path: File.join(dir, "v#{OsCtl::Repo::SCHEMA}")
    )
  end

  def build_image(repo, version:, distribution: 'alpine', vendor: 'vendor',
                  variant: 'variant', arch: 'x86_64', tags: [], image: %w[tar])
    OsCtl::Repo::Base::Image.new(
      repo,
      vendor,
      variant,
      arch,
      distribution,
      version,
      tags: tags,
      image: image
    )
  end

  def read_index_json(repo)
    JSON.parse(
      File.read(File.join(repo.path, 'INDEX.json')),
      symbolize_names: true
    )
  end

  it 'uses empty defaults when INDEX.json does not exist' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      index = described_class.new(repo)

      expect(index.exist?).to be(false)
      expect(index.images).to eq([])
      expect(index.find('vendor', 'variant', 'x86_64', 'alpine', '3.20')).to be_nil
    end
  end

  it 'loads persisted vendors and images' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      FileUtils.mkdir_p(repo.path)
      File.write(
        File.join(repo.path, 'INDEX.json'),
        index_json(
          vendors: { default: 'vendor', vendor: 'variant' },
          images: [
            image_record(
              vendor: 'vendor',
              variant: 'variant',
              arch: 'x86_64',
              distribution: 'alpine',
              version: '3.20',
              tags: %w[stable],
              formats: %w[tar]
            )
          ]
        )
      )

      index = described_class.new(repo)
      image = index.find('vendor', 'variant', 'x86_64', 'alpine', 'stable')

      expect(index.exist?).to be(true)
      expect(image.version).to eq('3.20')
      expect(image.tags).to eq(%w[stable])
    end
  end

  it 'adds new images' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      FileUtils.mkdir_p(repo.path)
      index = described_class.new(repo)
      image = build_image(repo, version: '3.20', tags: %w[stable], image: %w[tar zfs])

      index.add(image)

      expect(index.images).to contain_exactly(image)
    end
  end

  it 'replaces an existing image with the same tuple' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      FileUtils.mkdir_p(repo.path)
      index = described_class.new(repo)

      index.add(build_image(repo, version: '3.20', tags: %w[current], image: %w[tar zfs]))
      replacement = build_image(repo, version: '3.20', tags: %w[stable], image: %w[tar])

      index.add(replacement)

      expect(index.images).to eq([replacement])
    end
  end

  it 'removes reused tags from older images in the same stream' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      FileUtils.mkdir_p(repo.path)
      index = described_class.new(repo)
      older = build_image(repo, version: '3.19', tags: %w[stable current])
      newer = build_image(repo, version: '3.20', tags: %w[stable])

      index.add(older)
      index.add(newer)

      expect(index.find('vendor', 'variant', 'x86_64', 'alpine', '3.19').tags).to eq(%w[current])
      expect(index.find('vendor', 'variant', 'x86_64', 'alpine', 'stable')).to eq(newer)
    end
  end

  it 'keeps tags on images from other streams' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      FileUtils.mkdir_p(repo.path)
      index = described_class.new(repo)
      target = build_image(repo, version: '3.19', tags: %w[stable])
      other_distribution = build_image(
        repo, version: '3.18', distribution: 'debian', tags: %w[stable]
      )
      other_vendor = build_image(
        repo, version: '3.17', vendor: 'other-vendor', tags: %w[stable]
      )
      newer = build_image(repo, version: '3.20', tags: %w[stable])

      [target, other_distribution, other_vendor, newer].each { |image| index.add(image) }

      expect(index.find('vendor', 'variant', 'x86_64', 'alpine', '3.19').tags).to eq([])
      expect(index.find('vendor', 'variant', 'x86_64', 'debian', '3.18').tags).to eq(%w[stable])
      expect(
        index.find('other-vendor', 'variant', 'x86_64', 'alpine', '3.17').tags
      ).to eq(%w[stable])
    end
  end

  it 'finds images by version or tag' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      FileUtils.mkdir_p(repo.path)
      index = described_class.new(repo)
      image = build_image(repo, version: '3.20', tags: %w[current])

      index.add(image)

      expect(index.find('vendor', 'variant', 'x86_64', 'alpine', '3.20')).to eq(image)
      expect(index.find('vendor', 'variant', 'x86_64', 'alpine', 'current')).to eq(image)
    end
  end

  it 'deletes images' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      FileUtils.mkdir_p(repo.path)
      index = described_class.new(repo)
      image = build_image(repo, version: '3.20')

      index.add(image)
      index.delete(image)

      expect(index.images).to eq([])
    end
  end

  it 'persists default vendor' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      FileUtils.mkdir_p(repo.path)
      index = described_class.new(repo)

      index.set_default_vendor('vendor')
      index.save

      expect(read_index_json(repo)[:vendors]).to include(default: 'vendor')
    end
  end

  it 'persists default variant' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      FileUtils.mkdir_p(repo.path)
      index = described_class.new(repo)

      index.set_default_variant('vendor', 'variant')
      index.save

      expect(read_index_json(repo)[:vendors]).to include(vendor: 'variant')
    end
  end

  it 'saves and reloads images' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      FileUtils.mkdir_p(repo.path)
      index = described_class.new(repo)
      image = build_image(repo, version: '3.20', tags: %w[current], image: %w[tar zfs])

      index.add(image)
      index.set_default_vendor('vendor')
      index.set_default_variant('vendor', 'variant')
      index.save

      reloaded = described_class.new(repo)

      expect(reloaded.find('vendor', 'variant', 'x86_64', 'alpine', 'current').dump).to eq(
        image.dump
      )
      expect(read_index_json(repo)[:vendors]).to eq(default: 'vendor', vendor: 'variant')
    end
  end

  it 'returns a separate images array' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      FileUtils.mkdir_p(repo.path)
      index = described_class.new(repo)
      image = build_image(repo, version: '3.20')
      index.add(image)

      images = index.images
      images.clear

      expect(index.images).to eq([image])
    end
  end
end
