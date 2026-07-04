require 'libosctl'

module TestRunner
  class Cli::Command < OsCtl::Lib::Cli::Command
    def self.run(method)
      proc do |global_opts, opts, args|
        cmd = new(global_opts, opts, args)
        cmd.send(:load_extensions)
        cmd.method(method).call
      end
    end

    def list
      test_scripts = select_test_scripts(args[0])

      test_scripts.each do |ts|
        puts ts.path
      end
    end

    def test
      test_scripts = select_test_scripts(args[0])

      puts 'The following test scripts will be run:'
      test_scripts.each { |t| puts "  #{t.path}" }
      puts

      exec = TestRunner::Executor.new(
        test_scripts,
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
        test_config_path: opts['test-config']
      )
      results = exec.run

      return unless results.detect(&:unexpected_result?)

      raise 'one or more tests did not have expected results'
    end

    def debug
      require_args!('test')

      tsl = TestRunner::TestScriptList.new(system: opts['system'], test_config_path: opts['test-config'])
      test_script = tsl.by_path(args[0])

      ev = TestRunner::TestEvaluator.new(
        test_script.test,
        [test_script],
        system: opts['system'],
        test_config_path: opts['test-config'],
        state_dir: File.join(state_dir, "os-test-#{test_script.test.name}"),
        sock_dir: File.join(state_dir, 'socks'),
        default_timeout: opts['timeout'],
        destructive: false
      )
      ev.interactive
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
      tsl = TestRunner::TestScriptList.new(system: opts['system'], test_config_path: opts['test-config'])

      attr_filters = Cli::LabelFilters.new(opts['label'])
      tag_filters = Cli::TagFilters.new(opts['tag'])
      expr_filters = Array(opts['filter']).map { |expr| Cli::FilterExpression.new(expr) }

      tsl.filter do |ts|
        (pattern.nil? || ts.path_matches?(pattern)) \
        && attr_filters.pass?(ts) \
        && tag_filters.pass?(ts) \
        && expr_filters.all? { |expr| expr.pass?(ts) }
      end
    end

    def state_dir
      File.join(opts['state-dir'] || File.join(ENV['TMPDIR'] || '/tmp', 'os-test-runner'))
    end

    def load_extensions
      return if @extensions_loaded

      @extensions_loaded = true

      ext_dir = File.expand_path(File.join('tests', 'runner', 'extensions'), Dir.pwd)
      return unless Dir.exist?(ext_dir)

      Dir[File.join(ext_dir, '*.rb')].each do |file|
        load(file)
      end
    end
  end
end
