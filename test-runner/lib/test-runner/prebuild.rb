require 'digest'
require 'json'
require 'tmpdir'
require 'test-runner/gc_root'

module TestRunner
  class Prebuild
    DEFAULT_MEMORY_PER_JOB_MIB = 8192
    ROOT_DIRECTORY = 'os-test-runner-prebuilds'.freeze

    attr_reader :log_path

    def initialize(test_scripts, resource_pool:, state_dir:, memory_per_job_mib: DEFAULT_MEMORY_PER_JOB_MIB,
                   system: NixCli::DEFAULT_SYSTEM, test_config_path: nil, repo_root: nil, root_directory: nil)
      @scripts = test_scripts
      @pool = resource_pool
      @state_dir = state_dir
      @memory_per_job_mib = Integer(memory_per_job_mib)
      raise ArgumentError, 'prebuild-memory-per-job-mib must be positive' if @memory_per_job_mib <= 0

      @nix = NixCli.new(system:, test_config_path:, repo_root:)
      runtime = ENV.fetch('XDG_RUNTIME_DIR', nil)
      runtime = Dir.tmpdir if runtime.nil? || runtime.empty?
      @root_directory = root_directory || File.join(runtime, "#{ROOT_DIRECTORY}-#{Process.uid}")
    end

    def open
      prepared = @scripts.empty?
      return yield({}) if prepared

      FileUtils.mkdir_p(@state_dir)
      directory = Dir.mktmpdir('prebuild-', @state_dir)
      @log_path = File.join(directory, 'build.log')
      selected = @scripts.map(&:test).uniq.group_by { |test| identity(test) }
      requests = selected.map do |id, tests|
        test = tests.first
        { id:, path: test.path, testArgs: test.test_args || {}, templateArgs: test.template_args || {} }
      end
      File.write(File.join(directory, 'selection.json'), JSON.pretty_generate(requests))
      File.write(log_path, "Preparation selection: #{JSON.generate(requests)}\n")
      jobs = preparation_jobs
      warn "Preparing #{requests.length} selected tests; build log: #{log_path}"
      File.open(log_path, 'a') { |file| file.puts(@capacity_message) }

      GcRoot.new(root_directory: @root_directory).open do |root|
        with_cancellation do
          @nix.build_test_batch(requests, root, max_jobs: jobs, log_path:)
        end
        configs = load_manifest(root, selected)
        warn "Preparation complete: #{configs.length} test configurations; starting runtime"
        prepared = true
        yield(configs)
      end
    rescue StandardError => e
      raise if prepared

      raise "Test preparation failed: #{e.message}#{log_path ? "; build log: #{log_path}" : ''}"
    end

    protected

    def identity(test)
      Digest::SHA256.hexdigest(JSON.generate([test.path, test.test_args || {}, test.template_args || {}]))
    end

    def preparation_jobs
      inherited = @nix.local_max_jobs
      available = @pool.prebuild_memory_mib
      @capacity_message = "Preparation capacity: #{@pool.prebuild_memory_status}; " \
                          "usable=#{available.inspect} MiB, estimate=#{@memory_per_job_mib} MiB/job, " \
                          "inherited Nix local max-jobs=#{inherited}"
      if inherited == 0
        @capacity_message += '; max-jobs=0 (remote-only/substitution; remote memory is not sized)'
        warn @capacity_message
        return 0
      end

      if available.nil?
        raise 'Unable to detect preparation memory; set --max-memory-mib to a usable capacity'
      end

      jobs = [inherited, available / @memory_per_job_mib].min
      if jobs <= 0
        raise "Insufficient preparation memory: #{@capacity_message}; " \
              'adjust capacity, reserve, or --prebuild-memory-per-job-mib'
      end

      @capacity_message += "; preparation max-jobs=#{jobs}"
      warn @capacity_message
      jobs
    end

    def load_manifest(path, selected)
      manifest = JSON.parse(File.read(path))
      unless manifest.is_a?(Array) && manifest.all? { |entry| entry.is_a?(Hash) }
        raise 'Invalid preparation manifest'
      end

      ids = manifest.map { |entry| entry['id'] }
      unless ids.uniq.length == ids.length && ids.sort == selected.keys.sort
        raise 'Preparation manifest has missing, duplicate, or unexpected tests'
      end

      manifest.each_with_object({}) do |entry, configs|
        json = entry.fetch('json')
        unless json.is_a?(String) && json.start_with?('/nix/store/') && File.file?(json)
          raise "Invalid prepared JSON store path for #{entry.fetch('id')}"
        end

        selected.fetch(entry.fetch('id')).each do |test|
          scripts = @scripts.select { |script| script.test == test }
          configs[test] = TestConfig.load(test, config_path: json).validate!(scripts)
        end
      end
    end

    def with_cancellation
      handlers = %w[TERM HUP].to_h do |signal|
        [signal, Signal.trap(signal) { raise SignalException, signal }]
      end
      yield
    ensure
      handlers&.each { |signal, handler| Signal.trap(signal, handler) }
    end
  end
end
