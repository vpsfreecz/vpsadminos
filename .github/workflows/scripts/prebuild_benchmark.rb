require 'json'
require 'digest'
require 'open3'
require 'fileutils'
require 'socket'
require 'time'
require 'bundler'

# Temporary measurement code; product methods and resource settings are unchanged.
module PrebuildBenchmark
  PRODUCT_SHA = 'a2ccd72d08dc67f678d7f115a92ed5eeca50c1a1'.freeze
  CONFIG = 'tests/test-configs/ci.nix'.freeze
  SYSTEM = 'x86_64-linux'.freeze
  EXPECTED_TESTS = 127
  EXPECTED_SCRIPTS = 335

  def self.clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def self.command(flag, state)
    ['./test-runner.sh', 'test', flag, '--jobs', 'auto', '--test-config', CONFIG,
     '--system', SYSTEM, '--fresh', '--state-dir', state, '-t', 'ci']
  end

  def self.cli_environment
    Bundler.unbundled_env
  end

  def self.parse_log(text)
    selection = text.split("The following test scripts will be run:\n", 2)[1]&.split("\n\n", 2)&.first
    scripts = selection ? selection.lines.map(&:strip).reject(&:empty?).sort : nil
    completed = text.scan(/Run (\d+) test scripts of (\d+) tests in ([\d.]+) seconds/).last
    {
      'scripts' => scripts,
      'selection_digest' => scripts && Digest::SHA256.hexdigest(JSON.generate(scripts)),
      'completed_scripts' => completed && completed[0].to_i,
      'completed_tests' => completed && completed[1].to_i,
      'executor_reported_seconds' => completed && completed[2].to_f,
      'initial_resource_limits' => text[/Resource limits: ([^\n]+)/, 1],
      'resource_limit_updates' => text.lines.grep(/Resource limits updated: /).map(&:strip),
      'unexpected_failed_scripts' => summary_paths(text, 'Unexpectedly failed test scripts:'),
      'unexpected_successful_scripts' => summary_paths(text, 'Unexpectedly successful test scripts:'),
      'retries' => text.scan(%r{Retrying test '([^']+)' \((.*?)\) \(attempt (\d+)/\d+\)}).map { |path, names, attempt| [path, names.split(', ').sort, attempt] }.sort,
      'kernel_failures' => text.lines.grep(/stopped after .+ due to a guest kernel failure/).map(&:strip)
    }
  end

  def self.summary_paths(text, heading)
    section = text.split("#{heading}\n", 2)[1]
    return [] unless section

    section.lines.take_while { |line| line.match?(/\A\[[^\]]+\]   /) }.map { |line| line.sub(/\A\[[^\]]+\]   /, '').strip }.sort
  end

  def self.phase_marker(line)
    return 'executor_start' if line.match?(/Running \d+ scripts of \d+ tests,/)
    return 'executor_summary' if line.match?(/Run \d+ test scripts of \d+ tests in /)
    return 'preparing' if line.start_with?('Preparing ')
    return 'prepared' if line.start_with?('Preparation complete:')

    nil
  end

  def self.compare(legs, expected_digest)
    unless legs.size == 2 && legs.all? { |leg| leg.has_key?('wall_seconds') }
      return { 'complete' => false, 'qualification' => 'The comparison does not contain two completed CLI runs' }
    end

    a, b = legs
    complete = legs.all? do |leg|
      leg['completed_tests'] == EXPECTED_TESTS && leg['completed_scripts'] == EXPECTED_SCRIPTS &&
        leg['signal'].nil? && !leg['exit_status'].nil? && !leg['error']
    end
    equal_work = complete && legs.all? do |leg|
      leg['selection_digest'] == expected_digest && leg['completed_tests'] == EXPECTED_TESTS &&
        leg['completed_scripts'] == EXPECTED_SCRIPTS && Array(leg['owned_processes_remaining']).empty? && !leg['forced_cleanup'] && !leg['resource_identity_changed'] &&
        Array(leg['image_builds']).empty? && Array(leg['kernel_failures']).empty? && Array(leg['resource_limit_updates']).empty? && leg['oom_delta'] == 0
    end
    equal_work &&= !a['initial_resource_limits'].nil? && a['initial_resource_limits'] == b['initial_resource_limits'] &&
                   a['outcomes'] == b['outcomes'] && a['resource_identity'] == b['resource_identity'] &&
                   a.values_at('unexpected_failed_scripts', 'unexpected_successful_scripts', 'retries') == b.values_at('unexpected_failed_scripts', 'unexpected_successful_scripts', 'retries')
    ratio = b.fetch('wall_seconds').to_f / a.fetch('wall_seconds')
    {
      'complete' => complete,
      'comparable_work' => equal_work, 'both_successful' => legs.all? { |leg| leg['exit_status'] == 0 },
      'delta_seconds' => b.fetch('wall_seconds') - a.fetch('wall_seconds'),
      'ratio' => ratio, 'percent_change' => 100 * (ratio - 1),
      'qualification' => if equal_work
                           (legs.all? { |leg| leg['exit_status'] == 0 } ? 'One exploratory warm A/B pair; order and host effects remain' : 'Matching failures remain in both legs; totals include failure and cleanup delays')
                         else
                           'Unequal work, failures, image builds, OOM or capacity drift prevent a clean suite-time conclusion'
                         end
    }
  end

  class Run
    def initialize(product, root)
      @product = File.realpath(product)
      @root = File.expand_path(root)
      @report = { 'owned_cleanup_complete' => true, 'product_sha' => PRODUCT_SHA, 'harness_sha' => ENV.fetch('BENCHMARK_HARNESS_SHA', nil), 'legs' => [] }
      @report['measurement_notes'] = [
        'Wall seconds use a monotonic clock around each complete external CLI invocation, including cleanup.',
        'Phase receipts depend on buffered log delivery; intervals need not sum to wall seconds.',
        'The disabled executor span overlaps per-test evaluation and preparation. It is not VM-only runtime.',
        'Enabled global preparation includes aggregate evaluation and build checks. Both legs use warm image closures.',
        'The runner randomizes test order in each leg; host neighbors, filesystem caches and thermal effects remain uncontrolled.'
      ]
    end

    def run
      handlers = %w[TERM HUP].to_h { |signal| [signal, Signal.trap(signal) { raise SignalException, signal }] }
      require 'test-runner/cli'
      raise 'Product checkout differs from the fixed benchmark revision' unless capture('git', 'rev-parse', 'HEAD').strip == PRODUCT_SHA
      raise 'Tracked product source is dirty' unless capture('git', 'status', '--porcelain', '--untracked-files=no').empty?

      reject_overrides
      FileUtils.mkdir_p(@root)
      write('identity.json', snapshot)
      @report['product_tree'] = capture('git', 'rev-parse', 'HEAD^{tree}').strip
      @report['warmup_started_at'] = Time.now.utc.iso8601
      warm_start = PrebuildBenchmark.clock
      # Warm the normal CLI package check outside both timers.
      capture('nix', 'build', '--out-link', File.join(@root, 'runner-package'), '.#test-runner')
      smoke_cli
      TestRunner::RepositorySource.open(original_path: @product) do |source|
        config = source.resolve_path(CONFIG)
        scripts = TestRunner::TestScriptList.new(system: SYSTEM, test_config_path: config, repo_root: source.path)
                                            .matching(nil).select { |script| TestRunner::Cli::TagFilters.new(['ci']).pass?(script) }
        tests = scripts.map(&:test).uniq
        paths = scripts.map(&:path).sort
        raise "Unexpected native selection: #{tests.size} tests/#{paths.size} scripts" unless tests.size == EXPECTED_TESTS && paths.size == EXPECTED_SCRIPTS

        @report['selection_digest'] = Digest::SHA256.hexdigest(JSON.generate(paths))
        write('selection.json', paths)
        preflight(tests, source.path, config)
        TestRunner::Prebuild.new(
          scripts, resource_pool: TestRunner::ResourcePool.from_options({}), state_dir: File.join(@root, 'warmup'),
                   system: SYSTEM, test_config_path: config, repo_root: source.path
        ).open do |configs|
          configs.each_value do |cfg|
            raise "Missing warm JSON: #{cfg.config_path}" unless File.file?(cfg.config_path)

            verify_store_paths(cfg['machines'])
          end
          write('prepared.json', configs.to_h { |test, cfg| [test.path, cfg.config_path] })
          write('managed-disks.json', configs.to_h { |test, cfg| [test.path, cfg['machines'].transform_values { |m| m.slice('disks', 'rootDisk', 'diskImage') }] })
          @report['warmup_seconds'] = PrebuildBenchmark.clock - warm_start
          save
          [['A', '--no-prebuild'], ['B', '--prebuild']].each do |label, flag|
            leg = measure(label, flag)
            save
            unless safe_to_continue?(leg)
              raise "Leg #{label} ended without a complete, cleaned native workload; comparison stopped"
            end
          end
        end
      end
      @report['comparison'] = PrebuildBenchmark.compare(@report['legs'], @report['selection_digest'])
      save
      puts JSON.pretty_generate(@report['comparison'])
      @report['comparison']['comparable_work'] && @report['comparison']['both_successful'] ? 0 : 1
    rescue StandardError, SignalException => e
      @report['warmup_seconds'] ||= PrebuildBenchmark.clock - warm_start if warm_start
      @report['error'] = "#{e.class}: #{e.message}"
      @report['comparison'] = PrebuildBenchmark.compare(@report['legs'], @report['selection_digest'])
      save
      warn @report['error']
      1
    ensure
      handlers&.each { |signal, handler| Signal.trap(signal, handler) }
    end

    private

    def reject_overrides
      forbidden = ENV.keys.select do |name|
        name.start_with?('TEST_RUNNER_') && name != 'TEST_RUNNER_STATE_DIR' && name != 'TEST_RUNNER_NIXPKGS_PATH' && name != 'TEST_RUNNER_NIX_SYSTEM' && name != 'TEST_RUNNER_ROOT'
      end
      forbidden += ENV.keys.select { |name| name.start_with?('VPSADMINOS_') && name != 'VPSADMINOS_CONFIG' && name != 'VPSADMINOS_DEV_SHELL' }
      raise "Unexpected inherited suite overrides: #{forbidden.sort.join(', ')}" unless forbidden.empty? && ENV.fetch('VPSADMINOS_CONFIG', '').empty?
    end

    def capture(*cmd)
      out, status = Open3.capture2e(*cmd, chdir: @product)
      raise "#{cmd.first} failed (#{status.exitstatus || "signal #{status.termsig}"}): #{out}" unless status.success?

      out
    end

    def write(name, value)
      File.write(File.join(@root, name), JSON.pretty_generate(value))
    end

    def save
      FileUtils.mkdir_p(@root)
      write('timings.json', @report)
    end

    def smoke_cli
      output, status = Open3.capture2e(PrebuildBenchmark.cli_environment, './test-runner.sh', '--help', chdir: @product, unsetenv_others: true)
      File.write(File.join(@root, 'cli-smoke.log'), output)
      @report['cli_smoke'] = { 'exit_status' => status.exitstatus, 'signal' => status.termsig }
      save
      raise 'Packaged test-runner startup failed; see cli-smoke.log' unless status.success?
    end

    def read_optional(path)
      File.read(path).strip
    rescue Errno::ENOENT, Errno::EACCES, Errno::ESRCH
      nil
    end

    def snapshot
      detector = TestRunner::ResourcePool::HostResourceDetector.new
      group = TestRunner::ResourcePool.current_cgroup_path(nil)
      cgroup = group && File.join('/sys/fs/cgroup', group.sub(%r{\A/}, ''))
      disk = capture('df', '-Pk', @root)
      {
        'observed_at' => Time.now.utc.iso8601, 'hostname' => Socket.gethostname,
        'runner' => ENV.values_at('RUNNER_NAME', 'RUNNER_OS', 'RUNNER_ARCH'),
        'machine_id' => read_optional('/etc/machine-id'),
        'physical_host_id' => read_optional('/sys/class/dmi/id/product_uuid'),
        'cpu' => capture('lscpu'), 'affinity' => capture('taskset', '-pc', Process.pid.to_s),
        'cpus' => detector.cpus, 'assigned_memory_mib' => detector.memory_mib,
        'available_memory_mib' => detector.memory_available_mib,
        'shm_mib' => detector.shm_mib, 'shm_available_mib' => detector.shm_available_mib,
        'disk' => disk, 'disk_available_bytes' => disk.lines.last.split[3].to_i * 1024,
        'nix_version' => capture('nix', '--version').strip,
        'nix_max_jobs' => capture('nix', 'config', 'show', 'max-jobs').strip,
        'nix_cores' => capture('nix', 'config', 'show', 'cores').strip,
        'pressure' => %w[memory cpu io].to_h { |name| [name, read_optional("/proc/pressure/#{name}")] },
        'cgroup' => cgroup, 'cgroup_memory_max' => cgroup && read_optional(File.join(cgroup, 'memory.max')),
        'memory_events' => cgroup && read_optional(File.join(cgroup, 'memory.events')),
        'cpu_stat' => cgroup && read_optional(File.join(cgroup, 'cpu.stat')),
        'environment' => ENV.select { |name, _| name.start_with?('TEST_RUNNER_', 'VPSADMINOS_') || name == 'NIX_BUILD_CORES' }
      }
    end

    def preflight(tests, source, config)
      nix = TestRunner::NixCli.new(system: SYSTEM, test_config_path: config, repo_root: source)
      requests = tests.map { |test| { id: test.path, path: test.path, testArgs: test.test_args || {}, templateArgs: test.template_args || {} } }
      cmd = nix.send(:build_cmd, mode: 'testBatch', test_path: nil, test_args: nil, out_link: File.join(@root, 'dry-run-root'))
      cmd += ['--argstr', 'selectedTestsJson', JSON.generate(requests), '--dry-run']
      output = capture(*cmd)
      File.write(File.join(@root, 'nix-dry-run.log'), output)
      current = snapshot
      raise 'No available memory or shared-memory capacity' if [current['available_memory_mib'], current['shm_available_mib']].compact.any? { |v| v <= 0 }

      disk_available_kib = current['disk'].lines.last.split[3].to_i
      raise 'No free disk capacity' if disk_available_kib <= 0
      if current['pressure']['memory'].to_s.match?(/full avg10=(?!0\.00(?: |$))\d/)
        raise 'Active full memory pressure; benchmark requires operator investigation'
      end

      missing = output.lines.filter_map { |line| line.strip if line.strip.match?(%r{\A/nix/store/[^/]+\.drv\z}) }
      reject_uncached_kernels(missing)
      @report['preflight'] = {
        'resources' => current,
        'missing_derivations' => missing,
        'substitution_estimate' => output.lines.select { |line| line.include?('will be fetched') || line.include?('unpacked') },
        'disk_limitations' => 'Build temporary peaks and sparse VM disk peaks are unknown; logical disk sums are not capacity guarantees'
      }
      save
    end

    def reject_uncached_kernels(missing)
      return if missing.empty?

      document = JSON.parse(capture('nix', 'derivation', 'show', *missing))
      # Nix 2.34 wraps the map in a versioned envelope and uses store basenames.
      derivations = document.fetch('derivations', document)
      unless derivations.is_a?(Hash) && derivations.values.all? { |drv| drv.is_a?(Hash) && drv['env'].is_a?(Hash) } &&
             derivations.keys.map { |path| File.basename(path) }.sort == missing.map { |path| File.basename(path) }.sort
        raise 'Invalid Nix derivation inspection response for missing builds'
      end

      kernels = derivations.select { |_path, drv| drv.fetch('env')['pname'] == 'linux' }
      raise "Uncached kernel compilation required: #{kernels.keys.join(', ')}" unless kernels.empty?
    end

    def process_table
      Dir.glob('/proc/[0-9]*/stat').filter_map do |file|
        value = File.read(file)
        pid = File.basename(File.dirname(file)).to_i
        fields = value.sub(/\A\d+ \(.*\) /, '').split
        [pid, { 'ppid' => fields[1].to_i, 'start' => fields[19], 'state' => fields[0] }]
      rescue Errno::ENOENT, Errno::ESRCH, Errno::EACCES
        nil
      end.to_h
    end

    def descendants(table, parent)
      found = [parent]
      loop do
        extra = table.keys.select { |pid| found.include?(table[pid]['ppid']) && !found.include?(pid) }
        break if extra.empty?

        found.concat(extra)
      end
      found
    end

    def measure(label, flag)
      state = File.join(@root, "#{label}-state")
      raise "State already exists: #{state}" if File.exist?(state)

      before = snapshot
      cmd = PrebuildBenchmark.command(flag, state)
      leg = { 'label' => label, 'command' => cmd, 'before' => before, 'phase_receipts' => {} }
      @report['legs'] << leg
      save
      owned = {}
      start = PrebuildBenchmark.clock
      Open3.popen2e(PrebuildBenchmark.cli_environment, *cmd, chdir: @product, pgroup: true, unsetenv_others: true) do |stdin, output, waiter|
        stdin.close
        monitoring = true
        monitor = Thread.new do
          loop do
            table = process_table
            descendants(table, waiter.pid).each { |pid| owned[pid] ||= table[pid] if table[pid] }
            break unless monitoring && waiter.alive?

            sleep(0.25)
          end
        end
        begin
          File.open(File.join(@root, "#{label}.log"), 'w') do |log|
            output.each_line do |line|
              log.write(line)
              log.flush
              puts "#{label}: #{line}"
              marker = PrebuildBenchmark.phase_marker(line)
              leg['phase_receipts'][marker] ||= PrebuildBenchmark.clock - start if marker
            end
          end
          status = waiter.value
          leg['wall_seconds'] = PrebuildBenchmark.clock - start
          leg['exit_status'] = status.exitstatus
          leg['signal'] = status.termsig
        rescue StandardError, SignalException => e
          leg['error'] = "#{e.class}: #{e.message}"
          monitoring = false
          monitor.join
          table = process_table
          descendants(table, waiter.pid).each { |pid| owned[pid] ||= table[pid] if table[pid] }
          leg['forced_cleanup'] = true
          cleanup_owned(owned, state)
          status = waiter.value
          leg['exit_status'] = status.exitstatus
          leg['signal'] = status.termsig
          raise
        ensure
          monitoring = false
          monitor.join
          leg['wall_seconds'] ||= PrebuildBenchmark.clock - start
        end
      end
      leg
    ensure
      leg['wall_seconds'] ||= PrebuildBenchmark.clock - start if leg && start
      summarize_leg(leg, owned, state, flag) if leg && start
      save
    end

    def summarize_leg(leg, owned, state, flag)
      table = process_table
      leg['owned_processes_remaining'] = active_owned(owned, table, state).keys
      unless leg['owned_processes_remaining'].empty?
        leg['forced_cleanup'] = true
        cleanup_owned(owned, state)
      end
      after = snapshot
      leg['after'] = after
      leg['oom_delta'] = oom_events(after) - oom_events(leg['before'])
      leg['resource_identity'] = leg['before'].slice('hostname', 'machine_id', 'physical_host_id', 'affinity', 'cpus', 'assigned_memory_mib', 'shm_mib', 'cgroup_memory_max', 'nix_max_jobs', 'nix_cores')
      leg['resource_identity_changed'] = leg['resource_identity'] != after.slice(*leg['resource_identity'].keys)
      label = leg.fetch('label')
      text = File.read(File.join(@root, "#{label}.log"))
      leg.merge!(PrebuildBenchmark.parse_log(text))
      leg['outcomes'] = Dir.glob(File.join(state, '*', 'test-result.txt')).to_h { |path| [File.basename(File.dirname(path)), File.read(path).strip] }
      leg['image_builds'] = host_image_builds(label, state)
      leg['phase_seconds'] = {
        'cli_prefix_receipt' => leg['phase_receipts']['executor_start'],
        'executor_reported' => leg['executor_reported_seconds'],
        'tail_after_summary_receipt' => leg['phase_receipts']['executor_summary'] && (leg['wall_seconds'] - leg['phase_receipts']['executor_summary']),
        'global_preparation_receipt' => flag == '--prebuild' && leg['phase_receipts'].has_key?('prepared') && leg['phase_receipts'].has_key?('preparing') ? leg['phase_receipts']['prepared'] - leg['phase_receipts']['preparing'] : nil
      }
    rescue StandardError => e
      leg['error'] ||= "Unable to summarize leg: #{e.class}: #{e.message}"
    end

    def host_image_builds(label, state)
      # Guest shell/console builds are native test work, not host image misses.
      patterns = [
        File.join(state, 'os-test-*', 'test-runner.log'),
        File.join(state, 'os-test-*', 'attempt-*', 'test-runner.log'),
        File.join(state, 'prebuild-*', 'build.log')
      ]
      [File.join(@root, "#{label}.log"), *Dir.glob(patterns)].flat_map do |path|
        File.foreach(path).filter_map { |line| "#{path}: #{line.strip}" if line.match?(%r{building ['"]/nix/store/.+\.drv['"]}) }
      end
    end

    def active_owned(owned, table, state)
      # Include processes whose exact invocation-owned state appears in argv or
      # cwd, so an orphaned QEMU does not depend only on ancestry sampling.
      table.each do |pid, identity|
        next if pid == Process.pid

        cmd = read_optional("/proc/#{pid}/cmdline").to_s.tr("\0", ' ')
        cwd = begin
          File.readlink("/proc/#{pid}/cwd")
        rescue Errno::ENOENT, Errno::EACCES, Errno::ESRCH
          nil
        end
        owned[pid] ||= identity if cmd.include?("#{state}/") || cmd.split.include?(state) || cwd == state || cwd&.start_with?("#{state}/")
      end
      owned.select { |pid, identity| table[pid] && table[pid]['start'] == identity['start'] && table[pid]['state'] != 'Z' }
    end

    def cleanup_owned(owned, state)
      @report['owned_cleanup_complete'] = false
      %w[TERM KILL].each do |signal|
        active = active_owned(owned, process_table, state)
        active.each_key do |pid|
          Process.kill(signal, pid)
        rescue Errno::ESRCH
          next
        end
        20.times do
          break if active_owned(owned, process_table, state).empty?

          sleep(0.25)
        end
      end
      # Keep the existing warm roots alive if an uninterruptible owned process
      # survives bounded termination; do not start B or release its closures.
      until active_owned(owned, process_table, state).empty?
        warn 'Owned process cleanup is incomplete; retaining warm roots'
        sleep(5)
      end
      @report['owned_cleanup_complete'] = true
    end

    def verify_store_paths(value)
      case value
      when Hash
        value.each_value { |item| verify_store_paths(item) }
      when Array
        value.each { |item| verify_store_paths(item) }
      when String
        raise "Missing warm image path: #{value}" if value.start_with?('/nix/store/') && !File.exist?(value)
      end
    end

    def oom_events(sample)
      sample['memory_events'].to_s.lines.sum do |line|
        name, value = line.split
        name == 'oom_kill' ? value.to_i : 0
      end
    end

    def safe_to_continue?(leg)
      !leg['error'] && leg['signal'].nil? && !leg['forced_cleanup'] && !leg['resource_identity_changed'] && leg['kernel_failures'].empty? && leg['owned_processes_remaining'].empty? && leg['oom_delta'] == 0 &&
        leg['completed_tests'] == EXPECTED_TESTS && leg['completed_scripts'] == EXPECTED_SCRIPTS &&
        leg['outcomes'].size == EXPECTED_TESTS && leg['selection_digest'] == @report['selection_digest'] && leg['image_builds'].empty?
    end
  end
end

if $0 == __FILE__
  product, root = ARGV
  raise 'Expected product checkout and isolated benchmark state' unless product && root

  Dir.chdir(product) { exit PrebuildBenchmark::Run.new(product, root).run }
end
