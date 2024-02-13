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
      tl = TestRunner::TestList.new
      tests =
        if args[0]
          tl.filter { |t| t.path_matches?(args[0]) }
        else
          tl.all
        end

      tests.each do |test|
        puts test.path
      end
    end

    def test
      tl = TestRunner::TestList.new
      tests =
        if args[0]
          tl.filter { |t| t.path_matches?(args[0]) }
        else
          tl.all
        end

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

    def state_dir
      File.join(opts['state-dir'] || File.join(ENV['TMPDIR'] || '/tmp', 'os-test-runner'))
    end
  end
end
