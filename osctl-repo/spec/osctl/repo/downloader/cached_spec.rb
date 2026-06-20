# frozen_string_literal: true

require 'osctl/repo'

RSpec.describe OsCtl::Repo::Downloader::Cached do
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

  def build_repo(dir)
    OsCtl::Repo::Remote::Repository.new('https://repo.example').tap do |repo|
      repo.path = dir
    end
  end

  def build_downloader(repo)
    session = fake_http(request_get_responses: request_get_responses)
    [test_class.new(repo, session), session]
  end

  def cached_tar_path(repo, version: '3.20')
    File.join(
      repo.path,
      'vendor',
      'variant',
      'x86_64',
      'alpine',
      version,
      'image-archive.tar'
    )
  end

  def remote_tar_path(version: '3.20')
    "/v1/vendor/variant/x86_64/alpine/#{version}/image-archive.tar"
  end

  def image_index(version: '3.20', tags: %w[stable], formats: %w[tar])
    index_json(
      vendors: { default: 'vendor', vendor: 'variant' },
      images: [
        image_record(
          vendor: 'vendor',
          variant: 'variant',
          arch: 'x86_64',
          distribution: 'alpine',
          version: version,
          tags: tags,
          formats: formats
        )
      ]
    )
  end

  def write_cached_index(repo, **options)
    FileUtils.mkdir_p(repo.path)
    File.write(repo.index_path, image_index(**options))
  end

  it 'creates the cache directory and stores a downloaded index' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      request_get_responses['/v1/INDEX.json'] = [
        http_response(code: 200, body: image_index)
      ]
      downloader, = build_downloader(repo)

      expect(File).not_to exist(repo.path)

      images = downloader.list

      expect(File).to exist(repo.path)
      expect(File.read(repo.index_path)).to eq(image_index)
      expect(images.map(&:version)).to eq(%w[3.20])
    end
  end

  it 'keeps the existing index on 304 responses' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      write_cached_index(repo, version: '3.19', tags: %w[current])
      old_index = File.read(repo.index_path)

      request_get_responses['/v1/INDEX.json'] = [
        http_response(code: 304)
      ]
      downloader, http = build_downloader(repo)

      expect(downloader.list.map(&:version)).to eq(%w[3.19])
      expect(File.read(repo.index_path)).to eq(old_index)
      expect(http.request_get_requests).to eq(
        [
          [
            '/v1/INDEX.json',
            {
              'Accept-Encoding' => 'identity',
              'If-Modified-Since' => File.stat(repo.index_path).mtime.httpdate
            }
          ]
        ]
      )
    end
  end

  it 'downloads and caches a new image' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      request_get_responses['/v1/INDEX.json'] = [
        http_response(code: 200, body: image_index)
      ]
      request_get_responses[remote_tar_path] = [
        http_response(code: 200, body: %w[image data])
      ]
      downloader, = build_downloader(repo)

      returned_path = downloader.get(
        'vendor',
        'variant',
        'x86_64',
        'alpine',
        'stable',
        'tar'
      )

      expect(returned_path).to eq(File.absolute_path(cached_tar_path(repo)))
      expect(File.binread(cached_tar_path(repo))).to eq('imagedata')
    end
  end

  it 'stores the remote mtime for cached images' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      request_get_responses['/v1/INDEX.json'] = [
        http_response(code: 200, body: image_index)
      ]
      request_get_responses[remote_tar_path] = [
        http_response(
          code: 200,
          body: ['cached-image'],
          headers: { 'Last-Modified' => 'Tue, 02 Apr 2024 14:30:00 GMT' }
        )
      ]
      downloader, = build_downloader(repo)

      downloader.get('vendor', 'variant', 'x86_64', 'alpine', 'stable', 'tar')

      expect(File.mtime(cached_tar_path(repo)).to_i).to eq(
        Time.httpdate('Tue, 02 Apr 2024 14:30:00 GMT').to_i
      )
    end
  end

  it 'streams downloaded image data when a block is provided' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      request_get_responses['/v1/INDEX.json'] = [
        http_response(code: 200, body: image_index)
      ]
      request_get_responses[remote_tar_path] = [
        http_response(code: 200, body: %w[cached -image])
      ]
      downloader, = build_downloader(repo)

      output = +''
      returned_path = downloader.get(
        'vendor',
        'variant',
        'x86_64',
        'alpine',
        'stable',
        'tar'
      ) { |fragment| output << fragment }

      expect(output).to eq('cached-image')
      expect(returned_path).to eq(File.absolute_path(cached_tar_path(repo)))
    end
  end

  it 'propagates remote failures when force_check is true' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      write_cached_index(repo)
      FileUtils.mkdir_p(File.dirname(cached_tar_path(repo)))
      File.binwrite(cached_tar_path(repo), 'cached-image')
      request_get_responses['/v1/INDEX.json'] = Array.new(3) do
        http_response(code: 503, body: 'temporary failure')
      end
      downloader, = build_downloader(repo)

      expect do
        downloader.get(
          'vendor',
          'variant',
          'x86_64',
          'alpine',
          'stable',
          'tar',
          force_check: true
        )
      end.to raise_error(OsCtl::Repo::BadHttpResponse)

      expect(downloader.sleep_calls).to eq([5, 5])
    end
  end

  it 'falls back to cached images when remote checks fail' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      write_cached_index(repo)
      FileUtils.mkdir_p(File.dirname(cached_tar_path(repo)))
      File.binwrite(cached_tar_path(repo), 'cached-image')
      request_get_responses['/v1/INDEX.json'] = Array.new(3) do
        http_response(code: 503, body: 'temporary failure')
      end
      downloader, = build_downloader(repo)

      returned_path = downloader.get(
        'vendor',
        'variant',
        'x86_64',
        'alpine',
        'stable',
        'tar'
      )

      expect(returned_path).to eq(File.absolute_path(cached_tar_path(repo)))
    end
  end

  it 'streams from cache and returns the cached path when the remote fetch fails' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      write_cached_index(repo)
      FileUtils.mkdir_p(File.dirname(cached_tar_path(repo)))
      File.binwrite(cached_tar_path(repo), 'cached-image')
      request_get_responses['/v1/INDEX.json'] = Array.new(3) do
        http_response(code: 503, body: 'temporary failure')
      end
      downloader, = build_downloader(repo)

      output = +''
      returned_path = nil

      expect do
        returned_path = downloader.get(
          'vendor',
          'variant',
          'x86_64',
          'alpine',
          'stable',
          'tar'
        ) { |fragment| output << fragment }
      end.not_to raise_error

      expect(output).to eq('cached-image')
      expect(returned_path).to eq(File.absolute_path(cached_tar_path(repo)))
    end
  end

  it 're-raises the remote failure when cache is missing' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      write_cached_index(repo)
      FileUtils.mkdir_p(File.dirname(cached_tar_path(repo)))
      request_get_responses['/v1/INDEX.json'] = Array.new(3) do
        http_response(code: 503, body: 'temporary failure')
      end
      downloader, = build_downloader(repo)

      expect do
        downloader.get('vendor', 'variant', 'x86_64', 'alpine', 'stable', 'tar')
      end.to raise_error(OsCtl::Repo::BadHttpResponse)
    end
  end

  it 'propagates ImageNotFound from the remote index' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      request_get_responses['/v1/INDEX.json'] = [
        http_response(code: 200, body: index_json(images: []))
      ]
      downloader, = build_downloader(repo)

      expect do
        downloader.get('vendor', 'variant', 'x86_64', 'alpine', 'stable', 'tar')
      end.to raise_error(OsCtl::Repo::ImageNotFound)
    end
  end

  it 'propagates FormatNotFound from the remote index' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      request_get_responses['/v1/INDEX.json'] = [
        http_response(code: 200, body: image_index(formats: %w[zfs]))
      ]
      downloader, = build_downloader(repo)

      expect do
        downloader.get('vendor', 'variant', 'x86_64', 'alpine', 'stable', 'tar')
      end.to raise_error(OsCtl::Repo::FormatNotFound)
    end
  end

  it 'keeps cached images when revalidation returns 304' do
    with_tmpdir do |dir|
      repo = build_repo(dir)
      write_cached_index(repo)
      FileUtils.mkdir_p(File.dirname(cached_tar_path(repo)))
      File.binwrite(cached_tar_path(repo), 'cached-image')
      request_get_responses['/v1/INDEX.json'] = [
        http_response(code: 304)
      ]
      request_get_responses[remote_tar_path] = [
        http_response(code: 304)
      ]
      downloader, = build_downloader(repo)

      returned_path = downloader.get(
        'vendor',
        'variant',
        'x86_64',
        'alpine',
        'stable',
        'tar'
      )

      expect(returned_path).to eq(File.absolute_path(cached_tar_path(repo)))
      expect(File.binread(cached_tar_path(repo))).to eq('cached-image')
    end
  end
end
