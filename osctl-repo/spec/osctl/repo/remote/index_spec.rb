# frozen_string_literal: true

require 'osctl/repo'

RSpec.describe OsCtl::Repo::Remote::Index do
  let(:repo) { OsCtl::Repo::Remote::Repository.new('https://repo.example') }

  def index_data(vendors: { default: 'vendor', vendor: 'variant' }, images: nil)
    {
      vendors: vendors,
      images: images || [
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
    }
  end

  it 'loads from a json string' do
    index = described_class.from_string(repo, JSON.dump(index_data))

    expect(index.lookup('vendor', 'variant', 'x86_64', 'alpine', '3.20').version).to eq('3.20')
  end

  it 'loads from a file' do
    with_tmpdir do |dir|
      path = File.join(dir, 'INDEX.json')
      File.write(path, JSON.dump(index_data))

      index = described_class.from_file(repo, path)

      expect(index.lookup('vendor', 'variant', 'x86_64', 'alpine', 'stable').version).to eq(
        '3.20'
      )
    end
  end

  it 'looks up images by exact version' do
    index = described_class.new(repo, index_data)

    expect(index.lookup('vendor', 'variant', 'x86_64', 'alpine', '3.20').version).to eq('3.20')
  end

  it 'looks up images by tag' do
    index = described_class.new(repo, index_data)

    expect(index.lookup('vendor', 'variant', 'x86_64', 'alpine', 'stable').version).to eq('3.20')
  end

  it 'resolves the default vendor' do
    index = described_class.new(repo, index_data)

    expect(index.lookup('default', 'variant', 'x86_64', 'alpine', 'stable').vendor).to eq(
      'vendor'
    )
  end

  it 'resolves the default variant' do
    index = described_class.new(repo, index_data)

    expect(index.lookup('vendor', 'default', 'x86_64', 'alpine', 'stable').variant).to eq(
      'variant'
    )
  end

  it 'returns nil when no default vendor is configured' do
    index = described_class.new(repo, index_data(vendors: { default: nil }))

    expect(index.lookup('default', 'default', 'x86_64', 'alpine', 'stable')).to be_nil
  end

  it 'returns remote images' do
    index = described_class.new(repo, index_data)

    expect(index.images).to all(be_a(OsCtl::Repo::Remote::Image))
  end
end
