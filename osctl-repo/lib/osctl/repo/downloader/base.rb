require 'net/http'

module OsCtl::Repo
  class Downloader::Base
    def initialize(repo)
      @repo = repo
    end

    protected
    attr_reader :repo

    def connect
      uri = URI(repo.url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.start { |http| yield(http) }
    end

    def index_uri
      URI(repo.index_url)
    end
  end
end
