require 'libosctl'

module TestRunner
  class Cli::Command < OsCtl::Lib::Cli::Command
    def self.run(method)
      proc do |global_opts, opts, args|
        cmd = new(global_opts, opts, args)
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
        jobs: opts['jobs'],
        default_timeout: opts['timeout'],
        stop_on_failure: opts['stop-on-failure'],
        destructive: opts['destructive']
      )
      results = exec.run

      return unless results.detect(&:unexpected_result?)

      raise 'one or more tests did not have expected results'
    end

    def debug
      require_args!('test')

      tsl = TestRunner::TestScriptList.new
      test_script = tsl.by_path(args[0])

      ev = TestRunner::TestEvaluator.new(
        test_script.test,
        [test_script],
        state_dir: File.join(state_dir, "os-test-#{test_script.test.name}"),
        sock_dir: File.join(state_dir, 'socks'),
        default_timeout: opts['timeout'],
        destructive: false
      )
      ev.interactive
    end

    protected

    # @return [Array<TestScript>]
    def select_test_scripts(pattern)
      tsl = TestRunner::TestScriptList.new

      attr_filters = Cli::LabelFilters.new(opts['label'])
      tag_filters = Cli::TagFilters.new(opts['tag'])

      tsl.filter do |ts|
        (pattern.nil? || ts.path_matches?(pattern)) \
        && attr_filters.pass?(ts) \
        && tag_filters.pass?(ts)
      end
    end

    def state_dir
      File.join(opts['state-dir'] || File.join(ENV['TMPDIR'] || '/tmp', 'os-test-runner'))
    end
  end
end
