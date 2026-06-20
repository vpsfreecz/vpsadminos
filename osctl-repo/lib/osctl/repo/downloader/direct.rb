require 'net/http'
require 'osctl/repo/downloader/base'

module OsCtl::Repo
  # Download image in a specified format, no caching involved
  class Downloader::Direct < Downloader::Base
    # @return [Array<Remote::Image>]
    def list
      with_retries do
        connect do |http|
          body = +''

          request_get(http, index_uri) do |res|
            raise BadHttpResponse, res.code if res.code != '200'

            read_response_body(res) do |fragment|
              body << fragment
            end
          end

          Remote::Index.from_string(repo, body).images
        end
      end
    end

    # Streams fragments as they arrive. A failed transfer may have yielded a
    # prefix; callers must discard it. Never replay that prefix on retry.
    # yieldparam [String] downloaded data
    def get(vendor, variant, arch, dist, vtag, format, _opts = {}, &block)
      stream_started = false

      with_retries(retry_if: -> { !stream_started }) do
        connect do |http|
          body = +''

          request_get(http, index_uri) do |res|
            raise BadHttpResponse, res.code if res.code != '200'

            read_response_body(res) do |fragment|
              body << fragment
            end
          end

          index = Remote::Index.from_string(repo, body)
          t = index.lookup(vendor, variant, arch, dist, vtag)

          raise ImageNotFound, t unless t
          raise FormatNotFound.new(t, format) unless t.has_image?(format)

          request_get(http, URI(t.abs_image_url(format))) do |res|
            raise BadHttpResponse, res.code if res.code != '200'

            raise ArgumentError, 'stream block is required' unless block

            read_response_body(res) do |fragment|
              stream_started = true
              block.call(fragment)
            end
          end
        end
      end
    end
  end
end
