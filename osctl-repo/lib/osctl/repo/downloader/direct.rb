require 'net/http'

module OsCtl::Repo
  # Download template in a specified format, no caching involved
  class Downloader::Direct < Downloader::Base
    # @return [Array<Remote::Template>]
    def list
      connect do |http|
        index = Remote::Index.from_string(repo, http.get(index_uri.path).body)
        index.templates
      end
    end

    # yieldparam [String] downloaded data
    def download(vendor, variant, arch, dist, vtag, format)
      connect do |http|
        index = Remote::Index.from_string(repo, http.get(uri.path).body)
        t = index.lookup(vendor, variant, arch, dist, vtag)

        fail 'template not found' unless t
        fail 'rootfs not in given format' unless t.has_rootfs?(format)

        uri = URI(t.abs_rootfs_url(format))
        http.request_get(uri.path) do |res|
          fail 'bad response' unless res.code == '200'

          res.read_body do |fragment|
            yield(fragment)
          end
        end
      end
    end
  end
end
