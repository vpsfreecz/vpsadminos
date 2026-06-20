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

    DEFAULT_REQUEST_HEADERS = {
      'Accept-Encoding' => 'identity'
    }.freeze

    def connect
      uri = URI(repo.url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      callback_error = nil

      http.start do |session|
        yield session
      rescue StandardError => e
        callback_error = e
        raise
      end
    rescue *NETWORK_EXCEPTIONS => e
      raise if callback_error.equal?(e)

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

    def request_get(http, uri, headers = nil)
      callback_error = nil

      http.request_get(
        uri.request_uri,
        DEFAULT_REQUEST_HEADERS.merge(headers || {})
      ) do |response|
        yield response
      rescue StandardError => e
        callback_error = e
        raise
      end
    rescue *NETWORK_EXCEPTIONS => e
      raise if callback_error.equal?(e)

      raise NetworkError, e
    end

    def read_response_body(res)
      expected_length = response_content_length(res)
      actual_length = 0
      callback_error = nil

      res.read_body do |fragment|
        next_length = actual_length + fragment.bytesize

        if expected_length && next_length > expected_length
          raise NetworkError,
                "downloaded more than #{expected_length} bytes"
        end

        begin
          yield fragment
        rescue StandardError => e
          callback_error = e
          raise
        end

        actual_length = next_length
      end

      return if expected_length.nil? || actual_length == expected_length

      raise NetworkError,
            "downloaded #{actual_length} bytes, expected #{expected_length}"
    rescue *NETWORK_EXCEPTIONS => e
      raise if callback_error.equal?(e)

      raise NetworkError, e
    end

    def response_content_length(res)
      fields = res.get_fields('content-length')
      return if fields.nil?

      lengths = fields.flat_map { |field| field.split(',') }.map(&:strip)
      unless lengths.length == 1 && lengths.first.match?(/\A[0-9]+\z/)
        raise NetworkError, 'invalid or duplicate Content-Length header'
      end

      transfer_encodings = Array(res.get_fields('transfer-encoding'))
                           .flat_map { |field| field.split(',') }
                           .map(&:strip)
                           .reject(&:empty?)
      unless transfer_encodings.empty?
        raise NetworkError, 'response has both Content-Length and Transfer-Encoding'
      end

      Integer(lengths.first, 10)
    end

    def retryable_http_code?(code)
      code == 429 || code >= 500
    end
  end
end
