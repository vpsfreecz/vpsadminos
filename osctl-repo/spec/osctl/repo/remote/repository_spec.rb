# frozen_string_literal: true

require 'osctl/repo'

RSpec.describe OsCtl::Repo::Remote::Repository do
  it 'normalizes the remote url and default cache path' do
    repo = described_class.new('https://repo.example/images/')

    expect(repo.url).to eq("https://repo.example/images/v#{OsCtl::Repo::SCHEMA}")
    expect(repo.path).to eq("./v#{OsCtl::Repo::SCHEMA}")
  end

  it 'appends the schema version when setting the cache path' do
    repo = described_class.new('https://repo.example/images')

    repo.path = '/var/cache/osctl-repo'

    expect(repo.path).to eq("/var/cache/osctl-repo/v#{OsCtl::Repo::SCHEMA}")
  end

  it 'returns index paths and urls' do
    repo = described_class.new('https://repo.example/images')
    repo.path = '/var/cache/osctl-repo'

    expect(repo.index_path).to eq(
      "/var/cache/osctl-repo/v#{OsCtl::Repo::SCHEMA}/INDEX.json"
    )
    expect(repo.index_url).to eq(
      "https://repo.example/images/v#{OsCtl::Repo::SCHEMA}/INDEX.json"
    )
  end

  it 'reports whether the cached index exists' do
    with_tmpdir do |dir|
      repo = described_class.new('https://repo.example/images')
      repo.path = dir

      FileUtils.mkdir_p(repo.path)
      expect(repo.has_index?).to be(false)

      File.write(repo.index_path, '{}')
      expect(repo.has_index?).to be(true)
    end
  end

  it 'locks the cached index path' do
    with_tmpdir do |dir|
      repo = described_class.new('https://repo.example/images')
      repo.path = dir
      FileUtils.mkdir_p(repo.path)

      expect { |block| repo.lock_index(&block) }.to yield_control
    end
  end
end
