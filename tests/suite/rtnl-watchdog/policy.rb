require 'json'
require 'tmpdir'
require 'osctl/oomd'

$stdout.sync = true
Thread.abort_on_exception = true

def clock_ns
  Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
end

def controller_options(path)
  {
    interval: 1, cpu_percent: 10, memory_percent: 1, load_multiplier: 1_000_000,
    load_top: 10, restart_hits: 8, stop_hits: 40,
    rtnl_watchdog: { 'enable' => true, 'state_file' => path }
  }
end

if ARGV.first == 'dispatch'
  if ARGV[2] == 'disconnect-a'
    # Fault only the real client's established transport after the real
    # daemon guard accepts A. Keep the production executor and protocol parser.
    OsCtl::Oomd::ActionWorkers::ActionClient.prepend(Module.new do
      def cmd_response(command, **options, &progress)
        super do |message|
          progress.call(message)
          if options[:id] == 'watchdog-a' && message.start_with?('OOMd expected run accepted ')
            socket.close
            $stdout.puts JSON.generate(event: 'transport_closed_after_guard', id: options[:id],
                                       pid: options[:expected_init_pid], start: options[:expected_init_start_time])
          end
        end
      end
    end)
  end
  # A thin fixture around public production objects. The actual installed
  # sampler, state reader, action workers and guarded daemon path perform work.
  controller = OsCtl::Oomd::Controller.new(**controller_options(ARGV.fetch(1)))
  OsCtl::Lib::Logger.setup(:stdout)
  stopping = false
  %w[TERM INT].each { |sig| Signal.trap(sig) { stopping = true } }
  latest = SizedQueue.new(1)
  stream = IO.popen(%w[osctl -j ct top --oomd --rate 1], 'r')
  reader = Thread.new do
    stream.each_line do |line|
      row = JSON.parse(line)
      begin
        latest.pop(true)
      rescue ThreadError
        nil
      end
      latest.push(row)
    end
  end
  controller.start
  begin
    until stopping
      now = clock_ns
      data = begin
        latest.pop(true)
      rescue ThreadError
        nil
      end
      accepted = data ? controller.observe(data, now_ns: now) : controller.tick(now_ns: now)
      processed = clock_ns
      puts JSON.generate(
        event: 'controller', observed_monotonic_ns: now, processed_monotonic_ns: processed,
        raw: data, accepted: data && accepted,
        episode: controller.episode, restart_threshold: controller.restart_hits,
        scores: controller.export.map { |ct| { pool: ct.pool, id: ct.id, restart: ct.restart_hits, stop: ct.stop_hits } },
        inflight: controller.inflight.values, status: controller.status
      )
      raise 'real lean sampler exited' unless reader.alive?

      sleep(0.1)
    end
  ensure
    Process.kill('TERM', stream.pid) if reader.alive?
    reader.join(5)
    stream.close
    # A command slot is joined, never released by a fixture deadline. The
    # outer fixture releases RTNL before requesting this ordinary shutdown.
    controller.stop
  end
  puts JSON.generate(event: 'stopped', inflight: controller.inflight.values, status: controller.status)
  exit
end

# Controlled input checks exercise the installed parser/controller/worker code.
# They are not the real-CT dispatch witness and never execute a substitute CLI.
Dir.mktmpdir('watchdog-policy-', ARGV[1] || '/run') do |directory|
  path = File.join(directory, 'state.json')
  boot = File.read('/proc/sys/kernel/random/boot_id').strip
  now = clock_ns
  state_sequence = 0
  sample_sequence = 0
  dispatches = Queue.new
  workers = OsCtl::Oomd::ActionWorkers.new(
    size: 2, dry_run: false, executor: lambda { |permit|
      dispatches << permit
      true
    }, notifier: ->(_event) {}
  )
  baseline = Object.new
  def baseline.<<(_value); end
  def baseline.median = 100
  controller = OsCtl::Oomd::Controller.new(
    **controller_options(path), cpu_percent: 90, memory_percent: 95, load_top: 2,
                                load_multiplier: 2, host_load: baseline, workers: workers
  )
  publish = lambda do |state, epoch = 'one', observed = now|
    state_sequence += 1
    completed = state == 'healthy' ? observed : nil
    row = {
      schema: 1, boot_id: boot, epoch: epoch, sequence: state_sequence,
      observed_monotonic_ns: observed, probe_sequence: 1, state: state,
      dispatch_monotonic_ns: observed - 1_000_000_000,
      started_monotonic_ns: observed - 1_000_000_000,
      completed_monotonic_ns: completed, last_duration_ns: nil,
      expected_errno: 22, error_code: state == 'error' ? 5 : 0
    }
    File.write("#{path}.tmp", JSON.generate(row), mode: 'w', perm: 0o600)
    File.rename("#{path}.tmp", path)
    controller.tick(now_ns: now)
  end
  raw = lambda do |memory: 99, cpu: 100, load: 1, complete: true, extra: false|
    sample_sequence += 1
    now += 100_000_000
    publish.call('distressed')
    ct = { 'pool' => 'fixture', 'id' => 'a', 'valid' => true,
           'init_pid' => 123, 'init_start_time_ticks' => 456,
           'memory' => memory, 'memory_limit' => 100, 'cpu_usage' => cpu, 'cpu_limit' => 100,
           'loadavg' => [10, 0, 0] }
    rows = [{ 'pool' => nil, 'id' => '[host]', 'loadavg' => [20, 0, 0] }, ct]
    rows << ct.merge('id' => 'b', 'loadavg' => [30, 0, 0], 'memory_limit' => nil) if extra
    { 'oomd_schema' => 1, 'epoch' => 'sampler', 'sequence' => sample_sequence,
      'sample_started_monotonic_ns' => now - 50_000_000,
      'sample_completed_monotonic_ns' => now, 'complete' => complete,
      'measurement_window_started_monotonic_ns' => now - 100_000_000,
      'measurement_window_completed_monotonic_ns' => now,
      'loadavg' => [load, 0, 0], 'containers' => rows }
  end
  score = -> { controller.export.find { |ct| ct.id == 'a' } }
  observe = lambda { |**options|
    row = raw.call(**options)
    controller.observe(row, now_ns: now)
    row
  }
  controller.start
  begin
    publish.call('healthy')
    now += 100_000_000
    publish.call('healthy')
    raise 'ordinary threshold changed' unless controller.restart_hits == 8

    # Establish one real original-gate stop decision, then prove watchdog-only
    # raw hits AND misses do not alter that history.
    observe.call(load: 1000)
    raise 'original load gate did not score stop' unless score.call.stop_hits == 1

    now += 100_000_000
    publish.call('distressed')
    raise 'episode failed to clear restart evidence' unless controller.restart_hits == 2 && score.call.restart_hits == 0

    first = observe.call
    raise 'first fresh hit actioned' unless score.call.restart_hits == 1 && dispatches.empty?

    controller.observe(first, now_ns: now)
    raise 'duplicate sample scored' unless score.call.restart_hits == 1

    observe.call(memory: 94)
    raise 'memory miss did not decrement restart' unless score.call.restart_hits == 0

    observe.call(cpu: 89)
    raise 'CPU miss scored' unless score.call.restart_hits == 0

    observe.call(extra: true)
    raise 'host-inclusive top-N changed' unless score.call.restart_hits == 0
    raise 'watchdog-only decisions changed stop history' unless score.call.stop_hits == 1

    observe.call
    observe.call(complete: false)
    raise 'invalid required sample retained evidence' unless score.call.restart_hits == 0

    observe.call
    raise 'invalid gap reused old hit' unless dispatches.empty? && score.call.restart_hits == 1

    observe.call
    deadline = clock_ns + 1_000_000_000
    Thread.pass while dispatches.empty? && clock_ns < deadline
    raise 'two fresh full-policy hits did not dispatch' if dispatches.empty?

    now += 100_000_000
    publish.call('healthy')
    raise 'healthy completion retained override/evidence' unless controller.restart_hits == 8 && score.call.restart_hits == 0

    now += 100_000_000
    publish.call('error')
    raise 'probe error activated override' unless controller.episode.nil?

    now += 100_000_000
    publish.call('distressed', 'two')
    raise 'new epoch bound on its first frame' unless controller.episode.nil?

    now += 100_000_000
    publish.call('distressed', 'two')
    raise 'new epoch failed two-frame binding' unless controller.restart_hits == 2

    now += 2_000_000_000
    controller.tick(now_ns: now)
    raise 'stale watchdog retained override' unless controller.episode.nil? && controller.restart_hits == 8
    raise 'stale/recovery changed original stop history' unless score.call.stop_hits == 1

    puts JSON.generate(mode: 'controlled_inputs_only', original_stop_score: score.call.stop_hits,
                       fresh_dispatches: dispatches.size, predicates: %w[memory CPU host-inclusive-top-N],
                       guards: %w[duplicate incomplete healthy error stale epoch], no_real_actions: true)
  ensure
    controller.stop
  end
end
