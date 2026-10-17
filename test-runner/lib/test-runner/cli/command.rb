require 'libosctl'

module TestRunner
  class Cli::Command < OsCtl::Lib::Cli::Command
    def self.run(method)
      proc do |global_opts, opts, args|
        cmd = new(global_opts, opts, args)
        cmd.send(:with_repository_source) do
          cmd.send(:load_extensions)
          cmd.method(method).call
        end
      end
    end

    def list
      test_scripts = select_test_scripts(args[0])

      test_scripts.each do |ts|
        puts ts.path
      end
    end

    def test
      estimate = opts['prebuild-memory-per-job-mib']
      if estimate && Integer(estimate) <= 0
        raise ArgumentError, 'prebuild-memory-per-job-mib must be positive'
      end

      test_scripts = select_test_scripts(args[0])

      puts 'The following test scripts will be run:'
      test_scripts.each { |t| puts "  #{t.path}" }
      puts

      executor_options = {
        state_dir:,
        jobs: test_jobs(test_scripts),
        jobs_auto: jobs_auto?,
        max_memory_mib: opts['max-memory-mib'],
        max_shm_mib: opts['max-shm-mib'],
        max_cpus: opts['max-cpus'],
        memory_reserve_mib: opts['memory-reserve-mib'],
        shm_reserve_mib: opts['shm-reserve-mib'],
        cpu_reserve: opts['cpu-reserve'],
        memory_overcommit: opts['memory-overcommit'],
        shm_overcommit: opts['shm-overcommit'],
        cpu_overcommit: opts['cpu-overcommit'],
        resource_refresh_interval: opts['resource-refresh-interval'],
        status_interval: opts['status-interval'],
        verbose: opts['verbose'],
        default_timeout: opts['timeout'],
        stop_on_failure: opts['stop-on-failure'],
        destructive: opts['destructive'],
        recreate_disks: opts['fresh'],
        system: opts['system'],
        test_config_path:,
        repo_root:
      }
      results = if opts['prebuild']
                  pool = ResourcePool.from_options(executor_options)
                  Prebuild.new(
                    test_scripts,
                    resource_pool: pool,
                    state_dir:,
                    memory_per_job_mib: opts['prebuild-memory-per-job-mib'] || Prebuild::DEFAULT_MEMORY_PER_JOB_MIB,
                    system: opts['system'], test_config_path:, repo_root:
                  ).open do |configs|
                    pool.refresh_capacity
                    Executor.new(test_scripts, **executor_options, resource_pool: pool, prepared_configs: configs).run
                  end
                else
                  Executor.new(test_scripts, **executor_options).run
                end

      return unless results.detect(&:unexpected_result?)

      raise 'one or more tests did not have expected results'
    end

    def debug
      require_args!('test')

      tsl = TestRunner::TestScriptList.new(system: opts['system'], test_config_path:, repo_root:)
      test_script = tsl.by_path(args[0])

      directory = TestState.directory(state_dir, test_script.test)
      TestState.with_lock(directory) do
        ev = TestRunner::TestEvaluator.new(
          test_script.test,
          [test_script],
          system: opts['system'],
          test_config_path:,
          repo_root:,
          state_dir: directory,
          sock_dir: File.join(state_dir, 'socks'),
          default_timeout: opts['timeout'],
          destructive: false,
          recreate_disks: opts['fresh']
        )
        ev.interactive
      end
    end

    protected

    def test_jobs(test_scripts)
      return test_scripts.map(&:test).uniq.length if jobs_auto?

      ret = Integer(opts['jobs'])
      raise 'jobs must be positive' if ret <= 0

      ret
    end

    def jobs_auto?
      opts['jobs'].to_s == 'auto'
    end

    # @return [Array<TestScript>]
    def select_test_scripts(pattern)
      tsl = TestRunner::TestScriptList.new(system: opts['system'], test_config_path:, repo_root:)

      attr_filters = Cli::LabelFilters.new(opts['label'])
      tag_filters = Cli::TagFilters.new(opts['tag'])
      expr_filters = Array(opts['filter']).map { |expr| Cli::FilterExpression.new(expr) }

      tsl.matching(pattern).select do |ts|
        attr_filters.pass?(ts) \
        && tag_filters.pass?(ts) \
        && expr_filters.all? { |expr| expr.pass?(ts) }
      end
    end

    def state_dir
      File.join(opts['state-dir'] || File.join(ENV['TMPDIR'] || '/tmp', 'os-test-runner'))
    end

    def with_repository_source(&)
      RepositorySource.open(original_path: original_repo_root) do |source|
        @repository_source = source
        with_repository_environment(source.path, &)
      ensure
        @repository_source = nil
      end
    end

    def original_repo_root
      @original_repo_root ||= File.expand_path(ENV['TEST_RUNNER_REPO_ROOT'] || Dir.pwd)
    end

    def repo_root
      @repository_source&.path || original_repo_root
    end

    def test_config_path
      return opts['test-config'] unless @repository_source

      @repository_source.resolve_path(opts['test-config'])
    end

    def with_repository_environment(source_path)
      original_env = ENV.fetch('TEST_RUNNER_REPO_ROOT', nil)
      original_config = ENV.fetch('VPSADMINOS_CONFIG', nil)
      ENV['TEST_RUNNER_REPO_ROOT'] = source_path
      if original_config && !original_config.empty? && @repository_source
        ENV['VPSADMINOS_CONFIG'] = @repository_source.resolve_path(original_config)
      end

      yield
    ensure
      if original_env.nil?
        ENV.delete('TEST_RUNNER_REPO_ROOT')
      else
        ENV['TEST_RUNNER_REPO_ROOT'] = original_env
      end
      if original_config.nil?
        ENV.delete('VPSADMINOS_CONFIG')
      else
        ENV['VPSADMINOS_CONFIG'] = original_config
      end
    end

    def load_extensions
      return if @extensions_loaded

      @extensions_loaded = true

      ext_dir = File.join(original_repo_root, 'tests', 'runner', 'extensions')
      return unless Dir.exist?(ext_dir)

      Dir[File.join(ext_dir, '*.rb')].each do |file|
        load(file)
      end
    end
  end
end
