require 'net/http'

module OsCtl::Repo
  class Downloader::Base
    DEFAULT_ATTEMPTS = 3
    DEFAULT_WAIT = 5

    def initialize(repo)
      @repo = repo
    end

    protected

    attr_reader :repo

    NETWORK_EXCEPTIONS = [
      EOFError,
      IOError,
      SocketError,
      SystemCallError,
      Timeout::Error,
      OpenSSL::SSL::SSLError
    ].freeze

    def connect(&)
      uri = URI(repo.url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.start(&)
    rescue *NETWORK_EXCEPTIONS => e
      raise NetworkError, e
    end

    def index_uri
      URI(repo.index_url)
    end

    def with_retries(attempts: DEFAULT_ATTEMPTS, wait: DEFAULT_WAIT)
      attempt = 0

      begin
        attempt += 1
        yield
      rescue BadHttpResponse => e
        raise if attempt >= attempts || !retryable_http_code?(e.code)

        sleep(wait)
        retry
      rescue NetworkError => e
        raise if attempt >= attempts

        sleep(wait)
        retry
      end
    end

    def request_get(http, uri, headers = nil, &)
      if headers
        http.request_get(uri.request_uri, headers, &)
      else
        http.request_get(uri.request_uri, &)
      end
    rescue *NETWORK_EXCEPTIONS => e
      raise NetworkError, e
    end

    def retryable_http_code?(code)
      code == 429 || code >= 500
    end
  end
end
