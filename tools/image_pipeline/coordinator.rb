require 'digest'
require 'fileutils'
require 'securerandom'
require_relative 'control'

module ImagePipeline
  class Coordinator
    attr_reader :verified, :failures, :run, :ci_ready

    def initialize(control:, repository_url:, source:, plan:, state_dir:, run_id:, attempt:, lease_seconds:, full_ci:)
      @full_ci = full_ci
      @ci_ready = false
      @control = control
      @url = repository_url.sub(%r{/+\z}, '')
      @source = source
      @plan = plan
      @state_dir = state_dir
      @prefix = "#{run_id}/#{attempt}"
      @verified = []
      @failures = []
      @mutex = Mutex.new
      FileUtils.mkdir_p(state_dir)
      @run = control.call('begin', { 'id' => run_id, 'attempt' => attempt, 'source' => source,
                                     'expected' => plan.fetch('items').map { |item| item.slice('id', 'order', 'tags') },
                                     'defaults' => plan.fetch('defaults'),
                                     'lease_seconds' => lease_seconds },
                          key: "#{@prefix}/begin")
    end

    def bind(item, assignment)
      tuple = { 'vendor' => 'VENDOR', 'variant' => 'VARIANT', 'arch' => 'ARCH',
                'distribution' => 'DISTNAME', 'version' => 'RELVER' }
              .transform_values { |key| assignment.fetch('config').fetch(key) }
      descriptor = tuple.merge('formats' => assignment.fetch('config').fetch('DATASETS', '').empty? ? %w[tar zfs] : ['zfs'],
                               'config_digest' => assignment.fetch('config_digest'))
      @mutex.synchronize do
        mutate('bind', { 'item_id' => item.fetch('id'), 'attempt' => item.fetch('attempt', 1),
                         'descriptor' => descriptor }, item)
      end
    end

    def result(item, outcome)
      id = item.fetch('id')
      attempt = item.fetch('attempt', 0)
      assignment = outcome['assignment']
      if outcome['status'] == 'verified'
        outcome.fetch('files').each do |file|
          path = file.fetch('path')
          raise 'worker export changed before upload' unless File.size(path) == file.fetch('size') &&
                                                             Digest::SHA256.file(path).hexdigest == file.fetch('sha256')

          mutate('upload', file.slice('format', 'size', 'sha256').merge('item_id' => id, 'attempt' => attempt),
                 item, file: path, suffix: file.fetch('format'))
        end
      end
      params = { 'item_id' => id, 'attempt' => attempt, 'state' => outcome.fetch('status'),
                 'build_ok' => outcome['status'] == 'verified', 'tests_ok' => outcome['status'] == 'verified',
                 'config_digest' => assignment ? assignment.fetch('config_digest') : '',
                 'message' => outcome['message'].to_s[0, 2048] }
      mutate('result', params, item)
      (outcome['status'] == 'verified' ? @verified : @failures) << id
      File.write(File.join(@state_dir, "#{id}.json"), "#{JSON.pretty_generate(outcome)}\n")
      return unless outcome['status'] == 'verified'

      # Durable result acknowledgement owns the uploaded bytes now. Keep compact
      # manifests/logs, and delete only this run's acknowledged export scratch.
      outcome.fetch('files').each do |file|
        path = File.realpath(file.fetch('path'))
        raise 'export outside run scratch' unless path.start_with?("#{File.realpath(@state_dir)}/worker-")

        File.unlink(path)
      end
    end

    def finish
      mutate('finish')
      return nil unless failures.empty? && verified.length == @plan.fetch('items').length

      begin
        view = mutate('seal')
        url = "#{@url}/runs/#{run.fetch('key')}"
        return url unless @full_ci

        preflight(view)
        test_config = { 'imageRepository' => { 'url' => url, 'generation' => view.fetch('generation') } }
        File.write(File.join(@state_dir, 'test-config.json'), "#{JSON.pretty_generate(test_config)}\n")
        source = File.expand_path('../../tests/test-configs/ci.nix', __dir__)
        File.write(File.join(@state_dir, 'test-config.nix'),
                   "import #{source} // builtins.fromJSON (builtins.readFile ./test-config.json)\n")
        @ci_ready = true
        url
      rescue ControlError => e
        raise unless %w[not_ready invalid_state incomplete].include?(e.code)

        nil
      end
    end

    def renew(seconds)
      @control.call('renew', { 'lease_seconds' => seconds }, run_key: run.fetch('key'),
                                                             key: "#{@prefix}/renew/#{SecureRandom.uuid}")
    end

    protected

    def mutate(operation, params = {}, item = nil, file: nil, suffix: '')
      key = [@prefix, operation, item&.fetch('id'), item&.fetch('attempt', 1), suffix].compact.join('/')
      @control.call(operation, params, run_key: run.fetch('key'), key:, file:)
    end

    def preflight(view)
      catalog = view.fetch('catalog')
      @plan.fetch('dependencies').each do |dependency|
        vendor = dependency.fetch('vendor', catalog.fetch('vendors').fetch('default'))
        variant = dependency.fetch('variant') { catalog.fetch('vendors').fetch(vendor) }
        found = catalog.fetch('images').any? do |image|
          image['vendor'] == vendor && image['variant'] == variant &&
            image['arch'] == dependency.fetch('arch', 'x86_64') &&
            image['distribution'] == dependency.fetch('distribution') &&
            (image['version'] == dependency.fetch('version') || Array(image['tags']).include?(dependency.fetch('version')))
        end
        raise "missing suite image dependency: #{dependency}" unless found
      end
    end
  end
end
