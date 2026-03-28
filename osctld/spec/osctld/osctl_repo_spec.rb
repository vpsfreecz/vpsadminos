# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/osctl_repo'

RSpec.describe OsCtld::OsCtlRepo do
  subject(:osctl_repo) do
    Class.new(described_class) do
      attr_accessor :remote_results, :exec_results

      def osctl_repo(*)
        remote_results
      end

      def exec_as_repo_user(*)
        exec_results.shift
      end

      def log(*)
        nil
      end
    end.new(repo).tap do |instance|
      instance.remote_results = remote_results
      instance.exec_results = Array(exec_results)
    end
  end

  before do
    stub_const('OsCtld::Repository::Image', Class.new do
      attr_reader :attrs

      def initialize(attrs)
        @attrs = attrs
      end
    end)
  end

  let(:repo_class) do
    Struct.new(:cache_path, :url, :ident, :name, keyword_init: true)
  end
  let(:repo) do
    repo_class.new(
      cache_path: '/var/cache/osctl-repo',
      url: 'https://images.example.test',
      ident: 'tank:default',
      name: 'default'
    )
  end
  let(:remote_results) { nil }
  let(:exec_results) { [] }

  describe '#list_images' do
    it 'maps successful responses to repository images' do
      remote_results = [
        OsCtl::Repo::EXIT_OK,
        '[{"distribution":"alpine","version":"3.20"}]'
      ]
      allow(osctld_repo_spec_context = self).to receive(:remote_results).and_return(remote_results)

      images = osctl_repo.list_images

      expect(images.map(&:attrs)).to eq(
        [
          {
            distribution: 'alpine',
            version: '3.20'
          }
        ]
      )
    end

    it 'raises repository unavailable with a fallback message' do
      remote_results = [
        OsCtl::Repo::EXIT_NETWORK_ERROR,
        " \n"
      ]
      allow(osctld_repo_spec_context = self).to receive(:remote_results).and_return(remote_results)

      expect { osctl_repo.list_images }.to raise_error(
        OsCtld::ImageRepositoryUnavailable,
        'repository unavailable'
      )
    end
  end

  describe '#get_image_path' do
    let(:tpl) do
      {
        distribution: 'alpine',
        version: '3.20',
        arch: 'x86_64',
        vendor: 'default',
        variant: 'default'
      }
    end

    it 'returns the cache path on success' do
      remote_results = [
        OsCtl::Repo::EXIT_OK,
        "/cache/alpine-3.20.tar\n"
      ]
      allow(osctld_repo_spec_context = self).to receive(:remote_results).and_return(remote_results)

      expect(osctl_repo.get_image_path(tpl, :tar)).to eq('/cache/alpine-3.20.tar')
    end

    it 'returns nil when the requested format is unavailable' do
      remote_results = [
        OsCtl::Repo::EXIT_FORMAT_NOT_FOUND,
        ''
      ]
      allow(osctld_repo_spec_context = self).to receive(:remote_results).and_return(remote_results)

      expect(osctl_repo.get_image_path(tpl, :zfs)).to be_nil
    end

    it 'raises repository unavailable for network failures' do
      remote_results = [
        OsCtl::Repo::EXIT_HTTP_ERROR,
        'upstream failed'
      ]
      allow(osctld_repo_spec_context = self).to receive(:remote_results).and_return(remote_results)

      expect { osctl_repo.get_image_path(tpl, :tar) }.to raise_error(
        OsCtld::ImageRepositoryUnavailable,
        'upstream failed'
      )
    end
  end

  describe '#prune_images' do
    it 'returns deleted files on success and an empty list on failure' do
      exec_results = [
        [0, "/cache/a.tar\n/cache/b.tar\n"],
        [1, '']
      ]
      allow(osctld_repo_spec_context = self).to receive(:exec_results).and_return(exec_results)

      expect(osctl_repo.prune_images(older_than_days: 2)).to eq(
        [true, ['/cache/a.tar', '/cache/b.tar']]
      )
      expect(osctl_repo.prune_images).to eq([false, []])
    end
  end

  describe '#repo_error_message' do
    it 'returns a fallback when the repo output is empty' do
      expect(osctl_repo.send(:repo_error_message, " \n")).to eq('repository unavailable')
    end
  end
end
