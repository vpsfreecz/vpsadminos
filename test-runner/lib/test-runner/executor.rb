require 'fileutils'
require 'json'
require 'digest'

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
    # @option opts [Boolean] :recreate_disks
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

      tests.to_a.shuffle!.each_with_index do |(test, scripts), i|
        @queue << [i, test, scripts.shuffle!]
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

        result = nil

        test.attempts.times do |attempt|
          result = run_test_attempt(i, test, scripts, attempt)
          break if result.expected_result? || stop_work?

          sleep(5)
        end

        mutex.synchronize { results << result }
      end
    end

    def run_test_attempt(i, test, scripts, attempt)
      prefix = "[#{i + 1}/#{@test_count}]"
      script_list = scripts.map { |v| "##{v.name}" }.join(', ')

      if attempt > 0
        log("#{prefix} Retrying test '#{test.path}' (#{script_list}) (attempt #{attempt + 1}/#{test.attempts})")
      else
        log("#{prefix} Running test '#{test.path}' (#{script_list})")
      end

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

      result
    end

    def run_test(test, scripts, prefix:)
      t1 = Time.now
      dir = test_state_dir(test)
      r, w = IO.pipe

      # 4 ports for use with boot.qemu.networks.[i].socket.mcast.port
      mcast_ports = OsVm::PortReservation.get_ports(key: "test:#{test.path}", size: 4)

      pid = Process.fork do
        r.close
        FileUtils.mkdir_p(dir)

        out = File.open(File.join(dir, 'test-runner.log'), 'w')
        $stdout.reopen(out)
        $stderr.reopen(out)
        $stdin.close

        OsVm::PortReservation.reset_to_ports(mcast_ports)

        ev = TestRunner::TestEvaluator.new(
          test,
          scripts,
          system: opts[:system],
          test_config_path: opts[:test_config_path],
          state_dir: dir,
          sock_dir: test_sock_dir,
          default_timeout: opts[:default_timeout],
          destructive: opts[:destructive],
          recreate_disks: opts[:recreate_disks]
        )

        ev.run do |result_hash|
          w.puts(result_hash.to_json)
        end
      end

      w.close

      script_results = []
      test_runner_log = File.join(dir, 'test-runner.log')
      heartbeat_interval = 300
      next_heartbeat_at = Time.now + heartbeat_interval

      begin
        loop do
          timeout = [next_heartbeat_at - Time.now, 0].max
          ready = r.wait_readable(timeout)

          if ready.nil?
            elapsed = (Time.now - t1).round(2)
            msg = "#{prefix} Test '#{test.path}' still running after #{elapsed} seconds, log: #{test_runner_log}"
            last_line = last_nonempty_line(test_runner_log)
            msg += ", last output: #{last_line}" if last_line
            log(msg)
            next_heartbeat_at = Time.now + heartbeat_interval
            next
          end

          line = r.gets
          break if line.nil?

          next_heartbeat_at = Time.now + heartbeat_interval

          begin
            result_hash = JSON.parse(line)
          rescue JSON::ParserError
            warn "Unable to parse test script result json: #{line.inspect}"
            next
          end

          case result_hash['type']
          when 'script'
            test_script = test.test_scripts[result_hash['script']]
            script_result = TestScriptResult.from_h(test_script, result_hash)
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
          when 'example'
            status =
              if result_hash['success']
                if result_hash['pending']
                  'pending'
                elsif result_hash['skip']
                  'skipped'
                else
                  'succeeded'
                end
              elsif result_hash['pending']
                'unexpectedly succeeded'
              else
                'failed'
              end

            log("#{prefix} Example [#{result_hash['progress']}/#{result_hash['total']}] '#{result_hash['example']}' #{status} in #{result_hash['elapsed_time'].round(2)} seconds")
          end
        end
      rescue EOFError
        # pass
      end

      Process.wait(pid)

      OsVm::PortReservation.release_ports(key: "test:#{test.path}")

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
      File.join(state_dir, "os-test-#{test_state_key(test)}")
    end

    def test_sock_dir
      File.join(state_dir, 'socks')
    end

    def state_dir
      opts[:state_dir]
    end

    def test_state_key(test)
      slug = test.path.gsub(/[^A-Za-z0-9_.-]+/, '__')
      "#{slug}-#{Digest::SHA256.hexdigest(test.path)[0, 8]}"
    end

    def last_nonempty_line(path, max_bytes: 8192)
      return nil unless File.file?(path)

      size = File.size(path)
      return nil if size <= 0

      offset = [size - max_bytes, 0].max
      data = File.open(path, 'rb') do |f|
        f.seek(offset)
        f.read
      end

      data.lines.reverse_each do |line|
        stripped = line.strip
        return stripped unless stripped.empty?
      end

      nil
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def log(msg = '')
      mutex.synchronize { puts "[#{Time.now}] #{msg}" }
    end
  end
end
