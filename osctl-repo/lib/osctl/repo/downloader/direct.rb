require 'net/http'
require 'osctl/repo/downloader/base'

module OsCtl::Repo
  # Download image in a specified format, no caching involved
  class Downloader::Direct < Downloader::Base
    # @return [Array<Remote::Image>]
    def list
      connect do |http|
        index = Remote::Index.from_string(repo, http.get(index_uri.path).body)
        index.images
      end
    end

    # yieldparam [String] downloaded data
    def get(vendor, variant, arch, dist, vtag, format, _opts = {}, &block)
      connect do |http|
        index = Remote::Index.from_string(repo, http.get(index_uri.path).body)
        t = index.lookup(vendor, variant, arch, dist, vtag)

        raise 'image not found' unless t
        raise 'image not in given format' unless t.has_image?(format)

        uri = URI(t.abs_image_url(format))
        http.request_get(uri.path) do |res|
          raise 'bad response' unless res.code == '200'

          res.read_body(&block)
        end
      end
    end
  end
end
