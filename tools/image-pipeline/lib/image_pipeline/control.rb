require 'json'
require 'open3'
require 'digest'
require 'fileutils'

module ImagePipeline
  class ControlError < StandardError
    attr_reader :code

    def initialize(error)
      @code = error.fetch('code')
      super(error.fetch('message'))
    end
  end

  # SSH forced commands choose the role/socket. Worker guests receive neither
  # SSH credentials nor this transport. Stable IDs and request files survive
  # uncertain responses so an identical request can be retried verbatim.
  class Control
    def initialize(target, repository:, receipts:)
      raise ArgumentError, 'SSH target required' if target.to_s.empty? || target.start_with?('-')

      @target = target
      @repository = repository
      @receipts = receipts
      FileUtils.mkdir_p(receipts)
    end

    def call(operation, params = {}, run_key: nil, file: nil, key: operation)
      request = { 'request_id' => Digest::SHA256.hexdigest(key), 'operation' => operation,
                  'repository' => @repository, 'run_key' => run_key, 'params' => params }
      path = File.join(@receipts, "#{request.fetch('request_id')}.request.json")
      json = "#{JSON.generate(request)}\n"
      raise 'changed retry request' if File.exist?(path) && File.read(path) != json

      File.write(path, json)
      output = error = nil
      status = nil
      command = %w[ssh -T -oBatchMode=yes -oStrictHostKeyChecking=yes]
      command << "-oUserKnownHostsFile=#{ENV.fetch('IMAGE_SSH_KNOWN_HOSTS')}" if ENV['IMAGE_SSH_KNOWN_HOSTS']
      Open3.popen3(*command, @target) do |input, stdout, stderr, wait|
        out_reader = Thread.new { stdout.read }
        err_reader = Thread.new { stderr.read }
        begin
          input.write(json)
          File.open(file, 'rb') { |f| IO.copy_stream(f, input) } if file
        ensure
          input.close
        end
        output = out_reader.value
        error = err_reader.value
        status = wait.value
      end
      transport_failure = "SSH control failed (#{status}): #{error}"
      begin
        response = JSON.parse(output)
      rescue JSON::ParserError
        raise transport_failure unless status.success?

        raise
      end
      File.write(path.sub('.request.', '.response.'), "#{JSON.pretty_generate(response)}\n")
      # ctl writes the service response before exiting nonzero for !ok. Decode
      # that error before checking SSH status so conflict/superseded can recover.
      if response.is_a?(Hash) && response['ok'] == false && response['error'].is_a?(Hash) &&
         response['error'].values_at('code', 'message').all?(String)
        raise ControlError, response.fetch('error')
      end
      raise transport_failure unless status.success?
      raise 'invalid control response' unless response.is_a?(Hash) && response['ok'] == true

      response.fetch('result')
    end
  end
end
