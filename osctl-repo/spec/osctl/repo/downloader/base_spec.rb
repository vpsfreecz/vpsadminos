# frozen_string_literal: true

require 'osctl/repo'

RSpec.describe OsCtl::Repo::Downloader::Base do
  subject(:downloader) { test_class.new(repo) }

  let(:repo) { Struct.new(:url, keyword_init: true).new(url: repo_url) }
  let(:repo_url) { 'https://repo.example/images/v1' }
  let(:test_class) do
    Class.new(described_class) do
      attr_reader :sleep_calls

      public :connect, :request_get, :with_retries, :retryable_http_code?

      def sleep(wait)
        @sleep_calls ||= []
        @sleep_calls << wait
      end
    end
  end

  describe '#connect' do
    it 'builds a Net::HTTP client and enables ssl for https urls' do
      http = instance_spy(Net::HTTP)
      allow(Net::HTTP).to receive(:new).with('repo.example', 443).and_return(http)
      allow(http).to receive(:start).and_yield(:session)

      expect { |block| downloader.connect(&block) }.to yield_with_args(:session)
      expect(Net::HTTP).to have_received(:new).with('repo.example', 443)
      expect(http).to have_received(:use_ssl=).with(true)
      expect(http).to have_received(:start)
    end

    it 'disables ssl for http urls' do
      repo = Struct.new(:url, keyword_init: true).new(url: 'http://repo.example/images/v1')
      http = instance_spy(Net::HTTP)
      direct = test_class.new(repo)

      allow(Net::HTTP).to receive(:new).with('repo.example', 80).and_return(http)
      allow(http).to receive(:start).and_yield(:session)

      expect { |block| direct.connect(&block) }.to yield_with_args(:session)
      expect(Net::HTTP).to have_received(:new).with('repo.example', 80)
      expect(http).to have_received(:use_ssl=).with(false)
      expect(http).to have_received(:start)
    end

    it 'wraps network exceptions' do
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:start).and_raise(EOFError)

      expect { downloader.connect { nil } }.to raise_error(OsCtl::Repo::NetworkError)
    end
  end

  describe '#request_get' do
    let(:uri) { URI('https://repo.example/images/v1/INDEX.json') }

    it 'passes headers through to the http client' do
      http = instance_spy(Net::HTTP)

      allow(http).to receive(:request_get)
        .with('/images/v1/INDEX.json', { 'If-Modified-Since' => 'yesterday' })
        .and_yield(:response)

      expect { |block| downloader.request_get(http, uri, { 'If-Modified-Since' => 'yesterday' }, &block) }
        .to yield_with_args(:response)
      expect(http).to have_received(:request_get)
        .with('/images/v1/INDEX.json', { 'If-Modified-Since' => 'yesterday' })
    end

    it 'wraps network exceptions' do
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request_get).and_raise(Timeout::Error)

      expect { downloader.request_get(http, uri) }.to raise_error(OsCtl::Repo::NetworkError)
    end
  end

  describe '#with_retries' do
    it 'retries network errors until the block succeeds' do
      attempts = 0

      result = downloader.with_retries(attempts: 3, wait: 0) do
        attempts += 1
        raise OsCtl::Repo::NetworkError, EOFError if attempts < 3

        :ok
      end

      expect(result).to eq(:ok)
      expect(attempts).to eq(3)
      expect(downloader.sleep_calls).to eq([0, 0])
    end

    it 'retries retryable http responses' do
      attempts = 0

      result = downloader.with_retries(attempts: 3, wait: 0) do
        attempts += 1
        raise OsCtl::Repo::BadHttpResponse, 503 if attempts < 3

        :ok
      end

      expect(result).to eq(:ok)
      expect(attempts).to eq(3)
      expect(downloader.sleep_calls).to eq([0, 0])
    end

    it 'does not retry non-retryable http responses' do
      attempts = 0

      expect do
        downloader.with_retries(attempts: 3, wait: 0) do
          attempts += 1
          raise OsCtl::Repo::BadHttpResponse, 404
        end
      end.to raise_error(OsCtl::Repo::BadHttpResponse)

      expect(attempts).to eq(1)
      expect(downloader.sleep_calls).to be_nil
    end
  end

  describe '#retryable_http_code?' do
    it 'retries 429 and 5xx responses but not 404' do
      expect(downloader.retryable_http_code?(429)).to be(true)
      expect(downloader.retryable_http_code?(500)).to be(true)
      expect(downloader.retryable_http_code?(404)).to be(false)
    end
  end
end
