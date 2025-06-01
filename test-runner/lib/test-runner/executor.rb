require 'fileutils'
require 'json'

module TestRunner
  class Executor
    # @return [Array<TestScript>]
    attr_reader :test_scripts

    # @return [Hash]
    attr_reader :opts

    # @return [Array<TestResult>]
    attr_reader :results

    # @param tests [Array<TestScript>]
    # @param opts [Hash]
    # @option opts [String] :state_dir
    # @option opts [Integer] :jobs
    # @option opts [Integer] :default_timeout
    # @option opts [Boolean] :stop_on_failure
    # @option opts [Boolean] :destructive
    def initialize(test_scripts, **opts)
      @test_scripts = test_scripts
      @opts = opts
      @workers = []
      @queue = Queue.new
      @results = []
      @stop_work = false
      @mutex = Mutex.new

      fill_queue
    end

    # @return [Array<TestResult>]
    def run
      log("Running #{test_scripts.length} scripts of #{@test_count} tests, #{opts[:jobs]} tests at a time")
      log("State directory is #{state_dir}")
      t1 = Time.now

      opts[:jobs].times do |i|
        start_worker(i)
      end

      wait_for_workers

      log("Run #{results.inject(0) { |acc, r| acc + r.script_results.length }} test scripts of #{@test_count} tests in #{(Time.now - t1).round(2)} seconds")

      expected_successful = results.select do |r|
        r.expected_to_succeed? && r.successful?
      end

      expected_failed = results.select do |r|
        r.expected_to_fail? && r.failed?
      end

      unexpected_failed = results.select do |r|
        r.expected_to_succeed? && r.failed?
      end

      unexpected_successful = results.select do |r|
        r.expected_to_fail? && r.successful?
      end

      if expected_successful.any?
        log("#{expected_successful.length} tests successful")
      end

      if expected_failed.any?
        log("#{expected_failed.length} tests failed as expected")
      end

      if unexpected_failed.any?
        log("#{unexpected_failed.length} tests should have succeeded, but failed")
      end

      if unexpected_successful.any?
        log("#{unexpected_successful.length} tests should have failed, but succeeded")
      end

      if unexpected_failed.any?
        log('Unexpectedly failed test scripts:')

        unexpected_failed.each do |test_result|
          test_result.script_results.each do |test_script_result|
            next if test_script_result.expected_result?

            log("  #{test_script_result.test_script.path}")
          end
        end

        puts
      end

      if unexpected_successful.any?
        log('Unexpectedly successful test scripts:')

        unexpected_successful.each do |test_result|
          test_result.script_results.each do |test_script_result|
            next if test_script_result.expected_result?

            log("  #{test_script_result.test_script.path}")
          end
        end

        puts
      end

      results
    end

    protected

    attr_reader :workers, :queue, :mutex

    def fill_queue
      tests = {}

      test_scripts.each do |ts|
        tests[ts.test] ||= []
        tests[ts.test] << ts
      end

      tests.each_with_index do |(test, scripts), i|
        @queue << [i, test, scripts]
      end

      @test_count = tests.length
    end

    def start_worker(i)
      workers << Thread.new { run_worker(i) }
    end

    def wait_for_workers
      workers.each(&:join)
    end

    def run_worker(_w_i)
      loop do
        return if stop_work?

        begin
          i, test, scripts = queue.pop(true)
        rescue ThreadError
          return
        end

        prefix = "[#{i + 1}/#{@test_count}]"
        log("#{prefix} Running test '#{test.path}' (#{scripts.map { |v| "##{v.name}" }.join(', ')})")
        result = run_test(test, scripts, prefix:)

        secs = result.elapsed_time.round(2)

        if result.expected_result?
          if result.successful?
            log("#{prefix} Test '#{test.path}' successful in #{secs} seconds")
          else
            log("#{prefix} Test '#{test.path}' failed as expected in #{secs} seconds")
          end
        else # unexpected result
          if result.successful?
            log("#{prefix} Test '#{test.path}' unexpectedly succeeded in #{secs} seconds, see #{result.state_dir}")
          else
            log("#{prefix} Test '#{test.path}' failed after #{secs} seconds, see #{result.state_dir}")
          end

          stop_work! if opts[:stop_on_failure]
        end

        mutex.synchronize { results << result }
      end
    end

    def run_test(test, scripts, prefix:)
      t1 = Time.now
      dir = test_state_dir(test)
      r, w = IO.pipe

      pid = Process.fork do
        r.close
        FileUtils.mkdir_p(dir)

        out = File.open(File.join(dir, 'test-runner.log'), 'w')
        $stdout.reopen(out)
        $stderr.reopen(out)
        $stdin.close

        ev = TestRunner::TestEvaluator.new(
          test,
          scripts,
          state_dir: dir,
          sock_dir: test_sock_dir,
          default_timeout: opts[:default_timeout],
          destructive: opts[:destructive]
        )

        ev.run do |result_hash|
          w.puts(result_hash.to_json)
        end
      end

      w.close

      script_results = []

      begin
        r.each_line do |line|
          begin
            result_hash = JSON.parse(line)
          rescue JSON::ParserError
            warn "Unable to parse test script result json: #{line.inspect}"
            next
          end

          test_script = test.test_scripts[result_hash['script']]

          script_result = TestScriptResult.new(
            test_script,
            result_hash['success'],
            result_hash['elapsed_time']
          )

          script_results << script_result

          next if test_script.singleton?

          secs = script_result.elapsed_time.round(2)

          if script_result.expected_result?
            if script_result.successful?
              log("#{prefix} Script '#{test_script.path}' successful in #{secs} seconds")
            else
              log("#{prefix} Script '#{test_script.path}' failed as expected in #{secs} seconds")
            end
          else # unexpected result
            if script_result.successful?
              log("#{prefix} Script '#{test_script.path}' unexpectedly succeeded in #{secs} seconds")
            else
              log("#{prefix} Script '#{test_script.path}' failed after #{secs} seconds")
            end

            stop_work! if opts[:stop_on_failure]
          end
        end
      rescue EOFError
        # pass
      end

      Process.wait(pid)

      # Complement script results if some are missing
      scripts.each do |script|
        script_result = script_results.detect { |sr| sr.test_script == script }
        next if script_result

        script_results << TestScriptResult.new(script, false, -1)
      end

      result = TestResult.new(
        test,
        script_results,
        $?.exitstatus == 0,
        Time.now - t1,
        dir
      )

      File.open(File.join(dir, 'test-result.txt'), 'w') do |f|
        str =
          if result.expected_result?
            if result.successful?
              'expected_success'
            else
              'expected_failure'
            end
          elsif result.successful?
            'unexpected_success'
          else
            'unexpected_failure'
          end

        f.puts(str)
      end

      result
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

    def test_sock_dir
      File.join(state_dir, 'socks')
    end

    def state_dir
      opts[:state_dir]
    end

    def log(msg = '')
      mutex.synchronize { puts "[#{Time.now}] #{msg}" }
    end
  end
end
