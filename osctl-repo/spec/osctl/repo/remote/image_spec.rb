# frozen_string_literal: true

require 'osctl/repo'

RSpec.describe OsCtl::Repo::Remote::Image do
  def build_repo(dir)
    Struct.new(:path, :url, keyword_init: true).new(
      path: File.join(dir, "v#{OsCtl::Repo::SCHEMA}"),
      url: "https://repo.example/images/v#{OsCtl::Repo::SCHEMA}"
    )
  end

  def build_image(repo, image: %w[tar zfs], tags: %w[current])
    described_class.new(
      repo,
      'vendor',
      'variant',
      'x86_64',
      'alpine',
      '3.20',
      tags: tags,
      image: image
    )
  end

  it 'returns the absolute image url' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      image = build_image(repo)

      expect(image.abs_image_url('tar')).to eq(
        "https://repo.example/images/v#{OsCtl::Repo::SCHEMA}/" \
        'vendor/variant/x86_64/alpine/3.20/image-archive.tar'
      )
    end
  end

  it 'returns the cache path for an image' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      image = build_image(repo)

      expect(image.abs_cache_path('zfs')).to eq(
        File.join(
          repo.path,
          'vendor',
          'variant',
          'x86_64',
          'alpine',
          '3.20',
          'image-stream.tar'
        )
      )
    end
  end

  it 'reports whether a cached image exists' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      image = build_image(repo, image: %w[tar])
      FileUtils.mkdir_p(image.abs_dir_path)

      expect(image.cached?('tar')).to be(false)

      File.write(image.abs_cache_path('tar'), 'cached')
      expect(image.cached?('tar')).to be(true)
    end
  end

  it 'locks image downloads per format' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      image = build_image(repo, image: %w[tar])
      FileUtils.mkdir_p(image.abs_dir_path)

      expect { |block| image.lock('tar', &block) }.to yield_control
    end
  end

  it 'includes only cached formats in dump' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      image = build_image(repo)
      FileUtils.mkdir_p(image.abs_dir_path)
      File.write(image.abs_cache_path('tar'), 'cached')

      expect(image.dump).to include(
        cached: ['tar'],
        image: {
          'tar' => 'vendor/variant/x86_64/alpine/3.20/image-archive.tar',
          'zfs' => 'vendor/variant/x86_64/alpine/3.20/image-stream.tar'
        }
      )
    end
  end
end
