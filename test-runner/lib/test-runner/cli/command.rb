require 'libosctl'

module TestRunner
  class Cli::Command < OsCtl::Lib::Cli::Command
    def self.run(method)
      Proc.new do |global_opts, opts, args|
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

      ask_confirmation! do
        puts "The following tests will be run:"
        tests.each { |t| puts "  #{t.path}" }
      end

      exec = TestRunner::Executor.new(
        tests,
        state_dir: state_dir,
        jobs: opts['jobs'],
        default_timeout: opts['timeout'],
        stop_on_failure: opts['stop-on-failure'],
        destructive: opts['destructive'],
      )
      results = exec.run

      if results.detect(&:unexpected_result?)
        fail 'one or more tests did not have expected results'
      end
    end

    def debug
      require_args!('test')

      tl = TestRunner::TestList.new
      test = tl.by_path(args[0])

      ev = TestRunner::TestEvaluator.new(
        test,
        state_dir: File.join(state_dir, "os-test-#{test.name}"),
        sock_dir: File.join(state_dir, "socks"),
        default_timeout: opts['timeout'],
        destructive: false,
      )
      ev.interactive
    end

    protected
    def ask_confirmation
      return true if opts[:yes]

      yield
      STDOUT.write("\nContinue? [y/N]: ")
      STDOUT.flush
      STDIN.readline.strip.downcase == 'y'
    end

    def ask_confirmation!(&block)
      fail 'Aborted' unless ask_confirmation(&block)
    end

    def state_dir
      File.join(opts['state-dir'] || File.join(ENV['TMPDIR'] || '/tmp', 'os-test-runner'))
    end
  end
end
