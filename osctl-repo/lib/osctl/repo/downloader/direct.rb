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

            res.read_body do |fragment|
              body << fragment
            end
          end

          Remote::Index.from_string(repo, body).images
        end
      end
    end

    # yieldparam [String] downloaded data
    def get(vendor, variant, arch, dist, vtag, format, _opts = {}, &block)
      with_retries do
        connect do |http|
          body = +''

          request_get(http, index_uri) do |res|
            raise BadHttpResponse, res.code if res.code != '200'

            res.read_body do |fragment|
              body << fragment
            end
          end

          index = Remote::Index.from_string(repo, body)
          t = index.lookup(vendor, variant, arch, dist, vtag)

          raise ImageNotFound, t unless t
          raise FormatNotFound.new(t, format) unless t.has_image?(format)

          request_get(http, URI(t.abs_image_url(format))) do |res|
            raise BadHttpResponse, res.code if res.code != '200'

            res.read_body(&block)
          end
        end
      end
    end
  end
end
