# frozen_string_literal: true

require 'osctld/utils/container'
require 'osctld/repository'
require 'osctld/osctl_repo'

RSpec.describe OsCtld::Utils::Container do
  subject(:helper) { host_class.new }

  let(:host_class) do
    Class.new do
      include OsCtld::Utils::Container

      attr_accessor :opts
      attr_reader :progress_messages

      def initialize
        @progress_messages = []
      end

      def error!(msg)
        raise msg
      end

      def progress(message)
        progress_messages << message
      end
    end
  end

  it 'returns a named repository when requested' do
    host = host_class.new
    repo = Struct.new(:name, :enabled?, :pool, keyword_init: true).new(
      name: 'repo1',
      enabled?: true,
      pool: :tank
    )
    host.opts = { repository: 'repo1' }

    stub_const('OsCtld::DB::Repositories', Class.new do
      def self.find(_name, _pool); end

      def self.get; end
    end)
    allow(OsCtld::DB::Repositories).to receive(:find).with('repo1', :tank).and_return(repo)

    expect(host.get_repositories(:tank)).to eq([repo])
  end

  it 'returns enabled repositories for the pool when no name is requested' do
    host = host_class.new
    host.opts = {}
    repo1 = Struct.new(:enabled?, :pool, :name, keyword_init: true).new(
      enabled?: true,
      pool: :tank,
      name: 'repo1'
    )
    repo2 = Struct.new(:enabled?, :pool, :name, keyword_init: true).new(
      enabled?: false,
      pool: :tank,
      name: 'repo2'
    )

    stub_const('OsCtld::DB::Repositories', Class.new do
      def self.find(_name, _pool); end

      def self.get; end
    end)
    allow(OsCtld::DB::Repositories).to receive(:get).and_return([repo1, repo2])

    expect(host.get_repositories(:tank)).to eq([repo1])
  end

  it 'errors when image lookup is requested without any repositories' do
    host = host_class.new
    host.opts = {}

    expect do
      host.get_image_path!(
        [],
        distribution: 'alpine',
        version: '3.20',
        arch: 'x86_64',
        vendor: 'default',
        variant: 'default'
      )
    end.to raise_error('no enabled repositories are available for container images')
  end

  it 'holds the repository cache lock while yielding a remote image path' do
    locked = false
    repo = instance_double(OsCtld::Repository, name: 'default')
    osctl_repo = instance_double(OsCtld::OsCtlRepo)
    image = {
      distribution: 'almalinux',
      version: '9',
      arch: 'x86_64'
    }

    allow(repo).to receive(:with_cache_lock) do |&block|
      locked = true
      block.call
    ensure
      locked = false
    end
    allow(OsCtld::OsCtlRepo).to receive(:new).with(repo).and_return(osctl_repo)
    allow(osctl_repo).to receive(:get_image_path) do |tpl, format|
      expect(locked).to be(true)
      expect(tpl).to eq(image)

      format == :zfs ? '/cache/image.tar' : nil
    end

    yielded_locked = nil
    path = helper.with_repository_image_path!([repo], image) do |image_path|
      yielded_locked = locked
      image_path
    end

    expect(path).to eq('/cache/image.tar')
    expect(yielded_locked).to be(true)
  end
end
