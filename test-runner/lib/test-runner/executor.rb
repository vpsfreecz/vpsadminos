require 'fileutils'
require 'json'
require 'digest'
require 'test-runner/resource_pool'

module TestRunner
  class Executor
    DEFAULT_RESOURCE_REFRESH_INTERVAL = 15
    DEFAULT_STATUS_INTERVAL = 300
    TEST_HEARTBEAT_INTERVAL = 300

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
    # @option opts [Boolean] :jobs_auto
    # @option opts [Integer] :default_timeout
    # @option opts [Boolean] :stop_on_failure
    # @option opts [Boolean] :destructive
    # @option opts [Boolean] :recreate_disks
    # @option opts [Numeric] :resource_refresh_interval
    # @option opts [Numeric] :status_interval
    # @option opts [Boolean] :verbose
    # @option opts [String] :repo_root
    def initialize(test_scripts, **opts)
      @test_scripts = test_scripts
      @opts = opts
      @workers = []
      @pending = []
      @results = []
      @running_tests = {}
      @stop_work = false
      @mutex = Mutex.new
      @scheduler_mutex = Mutex.new
      @scheduler_cv = ConditionVariable.new
      @resource_pool = ResourcePool.from_options(opts)
      @last_resource_wait_log_at = nil
      @resource_refresh_interval = parse_resource_refresh_interval(opts[:resource_refresh_interval])
      @resource_monitor_mutex = Mutex.new
      @resource_monitor_cv = ConditionVariable.new
      @resource_monitor_stop = false
      @resource_monitor = nil
      @status_interval = parse_status_interval(opts[:status_interval])
      @status_monitor_mutex = Mutex.new
      @status_monitor_cv = ConditionVariable.new
      @status_monitor_stop = false
      @status_monitor = nil

      fill_queue
    end

    # @return [Array<TestResult>]
    def run
      log(
        "Running #{test_scripts.length} scripts of #{@test_count} tests, " \
        "at most #{opts[:jobs]} tests at a time#{opts[:jobs_auto] ? ' (auto)' : ''}"
      )
      log("Resource detection: #{resource_pool.capacity_status}")
      log("Resource limits: #{resource_pool.status}")
      log("State directory is #{state_dir}")
      t1 = Time.now

      begin
        start_resource_monitor
        start_status_monitor

        opts[:jobs].times do |i|
          start_worker(i)
        end

        wait_for_workers
      ensure
        stop_status_monitor
        stop_resource_monitor
      end

      log("Run #{results.inject(0) { |acc, r| acc + r.script_results.length }} test scripts of #{@test_count} tests in #{(Time.now - t1).round(2)} seconds")

      result_groups = classify_results(results)
      expected_successful = result_groups.fetch(:expected_successful)
      expected_failed = result_groups.fetch(:expected_failed)
      unexpected_failed = result_groups.fetch(:unexpected_failed)
      unexpected_successful = result_groups.fetch(:unexpected_successful)
      unexpected_failed_paths = unexpected_script_paths(results, successful: false)
      unexpected_successful_paths = unexpected_script_paths(results, successful: true)

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

      if unexpected_failed_paths.any?
        log('Unexpectedly failed test scripts:')

        unexpected_failed_paths.each { |path| log("  #{path}") }

        puts
      end

      if unexpected_successful_paths.any?
        log('Unexpectedly successful test scripts:')

        unexpected_successful_paths.each { |path| log("  #{path}") }

        puts
      end

      results
    end

    protected

    attr_reader :workers,
                :pending,
                :mutex,
                :scheduler_mutex,
                :scheduler_cv,
                :resource_pool,
                :resource_refresh_interval,
                :resource_monitor_mutex,
                :resource_monitor_cv,
                :running_tests,
                :status_interval,
                :status_monitor_mutex,
                :status_monitor_cv

    def fill_queue
      tests = {}

      test_scripts.each do |ts|
        tests[ts.test] ||= []
        tests[ts.test] << ts
      end

      tests.to_a.shuffle!.each_with_index do |(test, scripts), i|
        @pending << [i, test, scripts.shuffle!]
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

        reserved_test = reserve_next_test
        return if reserved_test.nil?

        i, test, scripts, resources = reserved_test
        result = nil

        begin
          mark_test_running(i, test)
          result = run_test_with_retries(i, test, scripts)
        ensure
          release_test_resources(resources)
          mark_test_finished(test, result)
        end
      end
    end

    def reserve_next_test
      scheduler_mutex.synchronize do
        loop do
          return nil if stop_work?
          return nil if pending.empty?

          i = schedulable_test_index

          if i
            item = pending.delete_at(i)
            _test_i, test, = item
            resources = test.resources

            resource_pool.reserve(resources)
            log_reserved_resources(test, resources)

            return [*item, resources]
          end

          log_resource_wait
          scheduler_cv.wait(scheduler_mutex)
        end
      end
    end

    def schedulable_test_index
      i = pending.index do |_test_i, test, _scripts|
        resource_pool.can_reserve?(test.resources)
      end

      return i unless i.nil?

      # Never deadlock the suite just because one test is larger than the
      # detected capacity. Run it alone and let QEMU or the host enforce the
      # real limit.
      if resource_pool.running == 0
        _test_i, test, = pending.first
        log(
          "WARNING: Test #{test.path} requests resources beyond the scheduler " \
          "limits (requested: #{test.resources.summary}; available: #{resource_pool.status}); " \
          'running it alone may exhaust the host'
        )
        return 0
      end

      nil
    end

    def release_test_resources(resources)
      scheduler_mutex.synchronize do
        resource_pool.release(resources)
        scheduler_cv.broadcast
      end
    end

    def refresh_resource_capacity
      scheduler_mutex.synchronize do
        refresh_resource_capacity_locked
      end
    end

    def refresh_resource_capacity_locked
      previous_status = resource_pool.status
      return unless resource_pool.refresh_capacity

      current_status = resource_pool.status
      scheduler_cv.broadcast

      log("Resource limits updated: #{current_status}") if previous_status != current_status
    end

    def start_resource_monitor
      @resource_monitor_stop = false
      @resource_monitor = Thread.new { run_resource_monitor }
    end

    def stop_resource_monitor
      thread = @resource_monitor
      return if thread.nil?

      resource_monitor_mutex.synchronize do
        @resource_monitor_stop = true
        resource_monitor_cv.signal
      end

      thread.join
      @resource_monitor = nil
    end

    def start_status_monitor
      return unless status_monitor_enabled?

      @status_monitor_stop = false
      @status_monitor = Thread.new { run_status_monitor }
    end

    def stop_status_monitor
      thread = @status_monitor
      return if thread.nil?

      status_monitor_mutex.synchronize do
        @status_monitor_stop = true
        status_monitor_cv.signal
      end

      thread.join
      @status_monitor = nil
    end

    def run_status_monitor
      loop do
        status_monitor_mutex.synchronize do
          return if @status_monitor_stop

          status_monitor_cv.wait(status_monitor_mutex, status_interval)
          return if @status_monitor_stop
        end

        log_status
      rescue StandardError => e
        log("Status monitor failed: #{e.class}: #{e.message}")
      end
    end

    def run_resource_monitor
      loop do
        resource_monitor_mutex.synchronize do
          return if @resource_monitor_stop

          resource_monitor_cv.wait(resource_monitor_mutex, resource_refresh_interval)
          return if @resource_monitor_stop
        end

        refresh_resource_capacity
      rescue StandardError => e
        log("Resource monitor failed: #{e.class}: #{e.message}")
      end
    end

    def parse_resource_refresh_interval(value)
      value = DEFAULT_RESOURCE_REFRESH_INTERVAL if value.nil? || value.to_s == ''

      ret = Float(value)
      raise ArgumentError, 'resource refresh interval must be positive' if ret <= 0

      ret
    end

    def parse_status_interval(value)
      value = DEFAULT_STATUS_INTERVAL if value.nil? || value.to_s == ''

      ret = Float(value)
      raise ArgumentError, 'status interval must be non-negative' if ret < 0

      ret
    end

    def status_monitor_enabled?
      status_interval > 0
    end

    def verbose?
      opts[:verbose]
    end

    def mark_test_running(i, test)
      mutex.synchronize do
        running_tests[test.path] = {
          index: i,
          test:,
          started_at: Time.now
        }
      end
    end

    def mark_test_finished(test, result)
      mutex.synchronize do
        running_tests.delete(test.path)
        results << result unless result.nil?
      end
    end

    def classify_results(result_list)
      {
        expected_successful: result_list.select { |r| r.expected_to_succeed? && r.successful? },
        expected_failed: result_list.select { |r| r.expected_to_fail? && r.failed? },
        unexpected_failed: result_list.select { |r| r.expected_to_succeed? && r.failed? },
        unexpected_successful: result_list.select { |r| r.expected_to_fail? && r.successful? }
      }
    end

    def status_snapshot
      pending_count = scheduler_mutex.synchronize { pending.length }
      finished_results, running_count = mutex.synchronize { [results.dup, running_tests.length] }
      result_groups = classify_results(finished_results)
      unexpected_failed = result_groups.fetch(:unexpected_failed).length
      unexpected_successful = result_groups.fetch(:unexpected_successful).length

      {
        status: unexpected_failed > 0 || unexpected_successful > 0 ? 'failed' : 'passing',
        expected_successful: result_groups.fetch(:expected_successful).length,
        expected_failed: result_groups.fetch(:expected_failed).length,
        unexpected_failed:,
        unexpected_successful:,
        unexpected_failed_paths: unexpected_script_paths(finished_results, successful: false),
        unexpected_successful_paths: unexpected_script_paths(finished_results, successful: true),
        running: running_count,
        remaining: pending_count
      }
    end

    def log_status
      snapshot = status_snapshot

      log(
        "Status: #{snapshot.fetch(:status)}; " \
        "#{snapshot.fetch(:expected_successful)} succeeded as expected, " \
        "#{snapshot.fetch(:expected_failed)} failed as expected, " \
        "#{snapshot.fetch(:unexpected_failed)} unexpectedly failed, " \
        "#{snapshot.fetch(:unexpected_successful)} unexpectedly succeeded; " \
        "#{snapshot.fetch(:running)} running, #{snapshot.fetch(:remaining)} remaining"
      )

      unless snapshot.fetch(:unexpected_failed_paths).empty?
        log("Unexpectedly failed test scripts: #{snapshot.fetch(:unexpected_failed_paths).join(', ')}")
      end

      return if snapshot.fetch(:unexpected_successful_paths).empty?

      log("Unexpectedly successful test scripts: #{snapshot.fetch(:unexpected_successful_paths).join(', ')}")
    end

    def unexpected_script_paths(test_results, successful:)
      test_results.flat_map(&:script_results)
                  .select(&:unexpected_result?)
                  .select { |script_result| successful ? script_result.successful? : script_result.failed? }
                  .map { |script_result| script_result.test_script.path }
                  .uniq
                  .sort
    end

    def log_reserved_resources(test, resources)
      log(
        "Reserved resources for '#{test.path}': #{resources.summary}; " \
        "pool: #{resource_pool.status}"
      )
    end

    def log_resource_wait
      now = Time.now
      return if @last_resource_wait_log_at && now - @last_resource_wait_log_at < 60

      @last_resource_wait_log_at = now
      waiting = pending.first(3).map do |_test_i, test, _scripts|
        "#{test.path} (#{test.resources.summary})"
      end.join(', ')

      log("Waiting for resources: pool: #{resource_pool.status}; pending: #{waiting}")
    end

    def run_test_with_retries(i, test, scripts)
      latest_script_results = {}
      remaining_scripts = scripts
      elapsed_time = 0
      last_result = nil
      attempt = 0

      loop do
        last_result = run_test_attempt(i, test, remaining_scripts, attempt)
        elapsed_time += last_result.elapsed_time

        last_result.script_results.each do |script_result|
          latest_script_results[script_result.test_script] = script_result
        end

        break if stop_work?

        remaining_scripts = remaining_scripts.select do |script|
          script_result = latest_script_results.fetch(script)

          script_result.unexpected_result? && attempt + 1 < script.attempts
        end

        break if remaining_scripts.empty?

        sleep(5)
        attempt += 1
      end

      build_accumulated_test_result(
        test,
        scripts,
        latest_script_results,
        elapsed_time,
        last_result
      )
    end

    def run_test_attempt(i, test, scripts, attempt)
      prefix = "[#{i + 1}/#{@test_count}]"
      script_list = scripts.map { |v| "##{v.name}" }.join(', ')
      max_attempts = scripts.map(&:attempts).max

      if attempt > 0
        log("#{prefix} Retrying test '#{test.path}' (#{script_list}) (attempt #{attempt + 1}/#{max_attempts})")
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

    def build_accumulated_test_result(test, scripts, latest_script_results, elapsed_time, last_result)
      script_results = scripts.map do |script|
        latest_script_results.fetch(script) { TestScriptResult.new(script, false, -1) }
      end

      TestResult.new(
        test,
        script_results,
        last_result&.successful? || false,
        elapsed_time,
        last_result&.state_dir || test_state_dir(test)
      )
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
          repo_root: opts[:repo_root],
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
      heartbeat_interval = TEST_HEARTBEAT_INTERVAL
      next_heartbeat_at = Time.now + heartbeat_interval

      begin
        loop do
          ready =
            if verbose?
              timeout = [next_heartbeat_at - Time.now, 0].max
              r.wait_readable(timeout)
            else
              r.wait_readable
            end

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

          next_heartbeat_at = Time.now + heartbeat_interval if verbose?

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
      scheduler_mutex.synchronize { scheduler_cv.broadcast }
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
