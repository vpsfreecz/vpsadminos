# frozen_string_literal: true

module FakeHttpHelpers
  class Response
    attr_reader :code, :body

    def initialize(code:, body: '', headers: {})
      @code = code.to_s
      @body = body
      @headers = headers.transform_keys { |k| k.to_s.downcase }
    end

    def [](key)
      @headers[key.to_s.downcase]
    end

    def read_body(&)
      return enum_for(:read_body) unless block_given?

      Array(body).each(&)
    end
  end

  class Session
    attr_reader :get_requests, :request_get_requests

    def initialize(get_responses: {}, request_get_responses: {})
      @get_responses = normalize(get_responses)
      @request_get_responses = normalize(request_get_responses)
      @get_requests = []
      @request_get_requests = []
    end

    def get(path)
      @get_requests << path
      fetch(@get_responses, path)
    end

    def request_get(path, headers = nil)
      @request_get_requests << [path, headers]
      response = fetch(@request_get_responses, path)

      if block_given?
        yield response
      else
        response
      end
    end

    private

    def normalize(map)
      map.transform_values do |responses|
        Array(responses).dup
      end
    end

    def fetch(map, key)
      queue = map.fetch(key) do
        raise "no fake HTTP response registered for #{key.inspect}"
      end

      raise "response queue for #{key.inspect} is empty" if queue.empty?

      entry = queue.shift
      entry.respond_to?(:call) ? entry.call : entry
    end
  end

  def http_response(code:, body: '', headers: {})
    Response.new(code: code, body: body, headers: headers)
  end

  def fake_http(get_responses: {}, request_get_responses: {})
    Session.new(
      get_responses: get_responses,
      request_get_responses: request_get_responses
    )
  end
end

RSpec.configure do |config|
  config.include FakeHttpHelpers
end
