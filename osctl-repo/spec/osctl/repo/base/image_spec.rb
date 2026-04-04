# frozen_string_literal: true

require 'osctl/repo'

RSpec.describe OsCtl::Repo::Base::Image do
  let(:repo) { Struct.new(:path, keyword_init: true).new(path: '/srv/repo') }

  def build_image(version:, tags: %w[current stable], image: %w[zfs tar])
    described_class.new(
      repo,
      'vendor',
      'variant',
      'x86_64',
      'alpine',
      version,
      tags: tags,
      image: image
    )
  end

  describe '.load' do
    it 'builds an image from serialized data' do
      image = described_class.load(
        repo,
        vendor: 'vendor',
        variant: 'variant',
        arch: 'x86_64',
        distribution: 'alpine',
        version: '3.20',
        tags: %w[stable current],
        image: {
          tar: 'vendor/variant/x86_64/alpine/3.20/image-archive.tar',
          zfs: 'vendor/variant/x86_64/alpine/3.20/image-stream.tar'
        }
      )

      expect(image.vendor).to eq('vendor')
      expect(image.variant).to eq('variant')
      expect(image.arch).to eq('x86_64')
      expect(image.distribution).to eq('alpine')
      expect(image.version).to eq('3.20')
      expect(image.tags).to eq(%w[stable current])
      expect(image.image).to eq(%w[tar zfs])
    end
  end

  describe '#dump' do
    it 'serializes sorted tags and image paths' do
      image = build_image(version: '3.20')

      expect(image.dump).to eq(
        vendor: 'vendor',
        variant: 'variant',
        arch: 'x86_64',
        distribution: 'alpine',
        version: '3.20',
        tags: %w[current stable],
        image: {
          'zfs' => 'vendor/variant/x86_64/alpine/3.20/image-stream.tar',
          'tar' => 'vendor/variant/x86_64/alpine/3.20/image-archive.tar'
        }
      )
    end
  end

  describe 'path helpers' do
    let(:image) { build_image(version: '3.20', tags: %w[stable], image: %w[tar]) }

    it 'returns the repository-relative and absolute paths' do
      expect(image.dir_path).to eq('vendor/variant/x86_64/alpine/3.20')
      expect(image.abs_dir_path).to eq('/srv/repo/vendor/variant/x86_64/alpine/3.20')
      expect(image.image_path('tar')).to eq(
        'vendor/variant/x86_64/alpine/3.20/image-archive.tar'
      )
      expect(image.version_image_path('tar')).to eq(
        'v1/vendor/variant/x86_64/alpine/3.20/image-archive.tar'
      )
      expect(image.abs_image_path('tar')).to eq(
        '/srv/repo/vendor/variant/x86_64/alpine/3.20/image-archive.tar'
      )
      expect(image.abs_tag_path('stable')).to eq(
        '/srv/repo/vendor/variant/x86_64/alpine/stable'
      )
    end
  end

  describe '#image_name' do
    let(:image) { build_image(version: '3.20') }

    it 'returns the expected file names for known formats' do
      expect(image.image_name('tar')).to eq('image-archive.tar')
      expect(image.image_name('zfs')).to eq('image-stream.tar')
    end
  end

  describe '#has_image?' do
    let(:image) { build_image(version: '3.20', image: %w[tar]) }

    it 'detects present and missing formats' do
      expect(image.has_image?('tar')).to be(true)
      expect(image.has_image?('zfs')).to be(false)
    end
  end

  describe 'comparison helpers' do
    it 'compares images by identity and sort order' do
      older = build_image(version: '3.19')
      newer = build_image(version: '3.20')
      same = build_image(version: '3.20')

      expect(newer).to eq(same)
      expect([newer, older].sort).to eq([older, newer])
    end
  end

  describe '#to_s' do
    it 'formats the image identity' do
      expect(build_image(version: '3.20').to_s).to eq(
        'alpine-3.20-x86_64-vendor-variant'
      )
    end
  end
end
