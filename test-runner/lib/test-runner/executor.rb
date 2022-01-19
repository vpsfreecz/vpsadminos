require 'fileutils'
require 'thread'

module TestRunner
  class Executor
    attr_reader :tests, :opts, :results

    # @param tests [Array<Test>]
    # @param opts [Hash]
    # @option opts [String] :state_dir
    # @option opts [Integer] :jobs
    # @option opts [Integer] :default_timeout
    # @option opts [Boolean] :stop_on_failure
    # @option opts [Boolean] :destructive
    def initialize(tests, opts)
      @tests = tests
      @opts = opts
      @workers = []
      @queue = Queue.new
      tests.each_with_index { |t, i| @queue << [i, t] }
      @results = []
      @stop_work = false
      @mutex = Mutex.new
    end

    # @return [Array<TestResult>]
    def run
      log("Running #{tests.length} tests, #{opts[:jobs]} at a time")
      log("State directory is #{state_dir}")
      t1 = Time.now

      opts[:jobs].times do |i|
        start_worker(i)
      end

      wait_for_workers

      log("Run #{results.length} tests in #{Time.now - t1} seconds")
      successful = results.select(&:successful?)
      failed = results.reject(&:successful?)
      log("#{successful.length} tests successful")
      log("#{failed.length} tests failed")

      if failed.any?
        log("Failed tests:\n#{failed.map { |r| "  #{r.test.path}" }.join("\n")}")
      end

      results
    end

    protected
    attr_reader :workers, :queue, :mutex

    def start_worker(i)
      workers << Thread.new { run_worker(i) }
    end

    def wait_for_workers
      workers.each(&:join)
    end

    def run_worker(w_i)
      loop do
        return if stop_work?

        begin
          i, t = queue.pop(true)
        rescue ThreadError
          return
        end

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
          stop_work! if opts[:stop_on_failure]
        end

        mutex.synchronize { results << result }
      end
    end

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
          default_timeout: opts[:default_timeout],
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

    def stop_work!
      @stop_work = true
    end

    def stop_work?
      @stop_work
    end

    def test_state_dir(test)
      File.join(state_dir, "os-test-#{test.name}")
    end

    def state_dir
      opts[:state_dir]
    end

    def log(msg)
      mutex.synchronize { puts "[#{Time.now}] #{msg}" }
    end
  end
end
