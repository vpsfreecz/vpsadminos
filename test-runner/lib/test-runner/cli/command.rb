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
      tests = select_tests(args[0])

      tests.each do |test|
        puts test.path
      end
    end

    def test
      tests = select_tests(args[0])

      puts 'The following tests will be run:'
      tests.each { |t| puts "  #{t.path}" }
      puts

      exec = TestRunner::Executor.new(
        tests,
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

      tl = TestRunner::TestList.new
      test = tl.by_path(args[0])

      ev = TestRunner::TestEvaluator.new(
        test,
        state_dir: File.join(state_dir, "os-test-#{test.name}"),
        sock_dir: File.join(state_dir, 'socks'),
        default_timeout: opts['timeout'],
        destructive: false
      )
      ev.interactive
    end

    protected

    # @return [Array<Test>]
    def select_tests(pattern)
      tl = TestRunner::TestList.new

      attr_filters = Cli::LabelFilters.new(opts['label'])
      tag_filters = Cli::TagFilters.new(opts['tag'])

      tl.filter do |test|
        (pattern.nil? || test.path_matches?(pattern)) \
        && attr_filters.pass?(test) \
        && tag_filters.pass?(test)
      end
    end

    def state_dir
      File.join(opts['state-dir'] || File.join(ENV['TMPDIR'] || '/tmp', 'os-test-runner'))
    end
  end
end
