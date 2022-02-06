module TestRunner
  class Cli::Command
    def self.run(method)
      Proc.new do |global_opts, opts, args|
        cmd = new(global_opts, opts, args)
        cmd.method(method).call
      end
    end

    attr_reader :gopts, :opts, :args

    def initialize(global_opts, opts, args)
      @gopts = global_opts
      @opts = opts
      @args = args
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

      fail 'one or more tests failed' if results.detect(&:failed?)
    end

    def debug
      require_args!('test')

      tl = TestRunner::TestList.new
      test = tl.by_path(args[0])

      ev = TestRunner::TestEvaluator.new(
        test,
        state_dir: File.join(state_dir, "os-test-#{test.name}"),
        default_timeout: opts['timeout'],
        destructive: false,
      )
      ev.interactive
    end

    protected
    # @param v [Array] list of required arguments
    def require_args!(*v)
      if v.count == 1 && v.first.is_a?(Array)
        required = v.first
      else
        required = v
      end

      return if args.count >= required.count

      arg = required[ args.count ]
      raise GLI::BadCommandLine, "missing argument <#{arg}>"
    end

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
