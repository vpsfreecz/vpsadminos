# frozen_string_literal: true

require 'osctl/repo'

RSpec.describe OsCtl::Repo::Downloader::Direct do
  subject(:downloader) { test_class.new(repo, http) }

  let(:repo) { OsCtl::Repo::Remote::Repository.new('https://repo.example') }
  let(:http) { fake_http(request_get_responses: request_get_responses) }
  let(:request_get_responses) { {} }
  let(:test_class) do
    Class.new(described_class) do
      attr_reader :sleep_calls

      def initialize(repo, http_session)
        super(repo)
        @http_session = http_session
      end

      protected

      def connect
        yield @http_session
      end

      def sleep(wait)
        @sleep_calls ||= []
        @sleep_calls << wait
      end
    end
  end

  it 'lists images from the remote index' do
    request_get_responses['/v1/INDEX.json'] = [
      http_response(
        code: 200,
        body: index_json(
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
    ]

    images = downloader.list

    expect(images.size).to eq(1)
    expect(images.first).to be_a(OsCtl::Repo::Remote::Image)
    expect(images.first.version).to eq('3.20')
    expect(images.first.tags).to eq(%w[stable])
  end

  it 'retries transient index failures and then succeeds' do
    request_get_responses['/v1/INDEX.json'] = [
      http_response(code: 503, body: 'temporary failure'),
      http_response(
        code: 200,
        body: index_json(
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
    ]

    expect(downloader.list.map(&:version)).to eq(%w[3.20])
    expect(downloader.sleep_calls).to eq([5])
  end

  it 'raises BadHttpResponse for non-retryable index responses' do
    request_get_responses['/v1/INDEX.json'] = [
      http_response(code: 404, body: 'missing')
    ]

    expect { downloader.list }.to raise_error(OsCtl::Repo::BadHttpResponse)
  end

  it 'streams image fragments to the provided block' do
    request_get_responses['/v1/INDEX.json'] = [
      http_response(
        code: 200,
        body: index_json(
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
    ]
    request_get_responses[
      '/v1/vendor/variant/x86_64/alpine/3.20/image-archive.tar'
    ] = [http_response(code: 200, body: %w[part-one part-two])]

    output = +''
    downloader.get(
      'vendor',
      'variant',
      'x86_64',
      'alpine',
      'stable',
      'tar'
    ) { |fragment| output << fragment }

    expect(output).to eq('part-onepart-two')
  end

  it 'raises ImageNotFound when the image does not exist' do
    request_get_responses['/v1/INDEX.json'] = [
      http_response(code: 200, body: index_json(images: []))
    ]

    expect do
      downloader.get('vendor', 'variant', 'x86_64', 'alpine', 'stable', 'tar')
    end.to raise_error(OsCtl::Repo::ImageNotFound)
  end

  it 'raises FormatNotFound when the requested format is unavailable' do
    request_get_responses['/v1/INDEX.json'] = [
      http_response(
        code: 200,
        body: index_json(
          images: [
            image_record(
              vendor: 'vendor',
              variant: 'variant',
              arch: 'x86_64',
              distribution: 'alpine',
              version: '3.20',
              tags: %w[stable],
              formats: %w[zfs]
            )
          ]
        )
      )
    ]

    expect do
      downloader.get('vendor', 'variant', 'x86_64', 'alpine', 'stable', 'tar')
    end.to raise_error(OsCtl::Repo::FormatNotFound)
  end

  it 'raises BadHttpResponse for non-200 image responses' do
    request_get_responses['/v1/INDEX.json'] = [
      http_response(
        code: 200,
        body: index_json(
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
    ]
    request_get_responses[
      '/v1/vendor/variant/x86_64/alpine/3.20/image-archive.tar'
    ] = [http_response(code: 403, body: 'forbidden')]

    expect do
      downloader.get('vendor', 'variant', 'x86_64', 'alpine', 'stable', 'tar')
    end.to raise_error(OsCtl::Repo::BadHttpResponse)
  end

  it 'surfaces network errors from the remote repository' do
    index_response = http_response(
      code: 200,
      body: index_json(
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

    request_get_responses['/v1/INDEX.json'] = [
      index_response,
      index_response,
      index_response
    ]
    request_get_responses[
      '/v1/vendor/variant/x86_64/alpine/3.20/image-archive.tar'
    ] = [
      -> { raise EOFError },
      -> { raise EOFError },
      -> { raise EOFError }
    ]

    expect do
      downloader.get('vendor', 'variant', 'x86_64', 'alpine', 'stable', 'tar')
    end.to raise_error(OsCtl::Repo::NetworkError)
  end
end
