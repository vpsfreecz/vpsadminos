require 'fileutils'

module TestRunner
  class Executor
    attr_reader :tests, :opts

    # @param tests [Array<Test>]
    # @param opts [Hash]
    # @option opts [String] :state_dir
    # @option opts [Boolean] :stop_on_failure
    # @option opts [Boolean] :destructive
    def initialize(tests, opts)
      @tests = tests
      @opts = opts
    end

    # @return [Array<TestResult>]
    def run
      ret = []

      log("Running #{tests.length} tests")
      log("State directory is #{state_dir}")
      t1 = Time.now

      tests.each_with_index do |t, i|
        prefix = "[#{i+1}/#{tests.length}]"
        log("#{prefix} Running test '#{t.path}'")
        result = run_test(t)

        if result.successful?
          log("#{prefix} Test '#{t.path}' successful in #{result.elapsed_time} seconds")
        else
          log(
            "#{prefix} Test '#{t.path}' failed after #{result.elapsed_time} "+
            "seconds, see #{result.state_dir}"
          )
          break if opts[:stop_on_failure]
        end

        ret << result
      end

      log("Run #{ret.length} tests in #{Time.now - t1} seconds")
      successful = ret.select(&:successful?)
      failed = ret.reject(&:successful?)
      log("#{successful.length} tests successful")
      log("#{failed.length} tests failed")

      if failed.any?
        log("Failed tests:\n#{failed.map { |r| "  #{r.test.path}" }.join("\n")}")
      end

      ret
    end

    protected
    def run_test(test)
      t1 = Time.now
      dir = test_state_dir(test)

      pid = Process.fork do
        FileUtils.mkdir_p(dir)

        out = File.open(File.join(dir, 'test-runner.log'), 'w')
        STDOUT.reopen(out)
        STDERR.reopen(out)
        STDIN.close

        ev = TestRunner::TestEvaluator.new(test, {
          state_dir: dir,
          destructive: opts[:destructive],
        })
        ev.run
      end

      Process.wait(pid)

      TestResult.new(
        test,
        $?.exitstatus == 0,
        Time.now - t1,
        dir
      )
    end

    def test_state_dir(test)
      File.join(state_dir, "os-test-#{test.name}")
    end

    def state_dir
      opts[:state_dir]
    end

    def log(msg)
      puts "[#{Time.now}] #{msg}"
    end
  end
end
