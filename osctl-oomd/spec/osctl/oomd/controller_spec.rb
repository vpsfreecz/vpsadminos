# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe OsCtl::Oomd::Controller do
  let(:watchdog) { instance_double(OsCtl::Oomd::WatchdogState, episode: nil, diagnostic: nil, details: nil) }
  let(:workers) do
    instance_double(OsCtl::Oomd::ActionWorkers, start: nil, stop: nil,
                                                evidence:, available?: true, completions: nil, notification_drops: 0, notification_failures: 0)
  end
  let(:host_load) { instance_double(OsCtl::Oomd::HostLoad, median: 100, median_with: 100, established?: true) }
  let(:permits) { [] }
  let(:controller) do
    described_class.new(interval:, cpu_percent: 90, memory_percent: 95, load_multiplier: 2,
                        load_top: 2, restart_after_seconds: 90, stop_after_seconds: 600, rtnl_watchdog: { 'enable' => true },
                        watchdog:, workers:, host_load:)
  end

  def evidence_lines = (@evidence_lines ||= [])

  def evidence
    @evidence ||= OsCtl::Oomd::Evidence.new(writer: lambda { |bytes|
      evidence_lines << bytes
      bytes.bytesize
    }).tap(&:start)
  end

  after { evidence.stop }

  before do
    controller.child_started
    allow(host_load).to receive(:<<)
    allow(workers).to receive(:dispatch) { |permit|
      permits << permit
      true
    }
  end

  def ns(seconds) = (seconds * 1_000_000_000).to_i
  def interval = 15

  def row(id = 'a', **changes)
    {
      'pool' => 'tank', 'id' => id, 'loadavg' => [10, 0, 0], 'memory' => 98,
      'memory_limit' => 100, 'cpu_usage' => 95.0, 'cpu_limit' => 100,
      'init_pid' => 42, 'init_start_time_ticks' => 123, 'group_path' => "ct.#{id}/user-owned",
      'run_verified' => true, 'nproc' => 1, 'errors' => {}
    }.merge(changes.transform_keys(&:to_s)).tap do |ct|
      ct['loadavg'] = ct['loadavg'].first(3).fill(0, ct['loadavg'].length...3)
      %w[memory_limit cpu_limit].each { |key| ct["#{key}_state"] = ct[key] ? 'limited' : 'unlimited' }
    end
  end

  def frame(sequence, time, rows = [row], **changes)
    frame = {
      'top_schema' => 2, 'epoch' => 'sampler', 'sequence' => sequence + 1, 'complete' => true, 'invalid_reason' => nil,
      'collectors' => { 'netif' => false, 'zfs' => false, 'iostat' => false },
      'sample_started_monotonic_ns' => ns(time) - ns(0.1), 'sample_completed_monotonic_ns' => ns(time),
      'measurement_window_started_monotonic_ns' => [ns(time) - ns(interval) - ns(0.1), ns(0.1)].max,
      'measurement_window_completed_monotonic_ns' => ns(time),
      'loadavg' => [10, 0, 0], 'memory' => { 'used' => 200 }, 'cpu' => { 'user' => 10 },
      'inventory_complete' => true, 'state_counts' => { 'running' => rows.size }
    }.merge(changes.transform_keys(&:to_s))
    window = frame['measurement_window_started_monotonic_ns'] || (ns(time) - ns(interval) - ns(0.1))
    frame['previous_sample_started_monotonic_ns'] = window
    frame['loadavg'] = frame['loadavg'].first(3).fill(0, frame['loadavg'].length...3)
    host = { 'id' => '[host]', 'pool' => nil, 'init_pid' => nil, 'init_start_time_ticks' => nil,
             'loadavg' => frame['loadavg'], 'memory' => 101 }
    frame['containers'] = rows.map do |ct|
      ct.merge('cpu_baseline_sequence' => ct['cpu_usage'] && sequence,
               'cpu_window_started_monotonic_ns' => ct['cpu_usage'] && window)
    end + [host]
    frame
  end

  def observe(sequence, time, rows = [row], **changes)
    result = controller.observe(frame(sequence, time, rows, **changes), now_ns: ns(time))
    Timeout.timeout(2) { Thread.pass until evidence.status[:evidence_pending_records] == 0 }
    result
  end

  def seed(sequence, time, rows = [row])
    warmup = rows.map { |ct| ct.merge('cpu_usage' => nil, 'errors' => { 'cpu_usage' => 'initial_baseline' }) }
    observe(sequence, time, warmup, complete: false, invalid_reason: 'initial_baseline', measurement_window_started_monotonic_ns: nil)
  end

  def enter_episode(time = 1, token = ['watchdog', 1])
    allow(watchdog).to receive(:episode).and_return(token)
    controller.tick(now_ns: ns(time))
  end

  def score = controller.export.find { |ct| ct.id == 'a' }

  context 'with independent exposure and both acute gates disabled' do
    let(:controller) do
      cache_reader = instance_double(OsCtl::Oomd::ExposureState, gap: false)
      event_publisher = instance_double(OsCtl::Oomd::ExposureEvents, status: {}, start: nil, stop: nil, publish: true)
      exposure = OsCtl::Oomd::RtnlExposure.new(interval: 15, cpu_percent: 90, memory_percent: 95, load_top: 2,
                                               settings: { 'enable' => true }, reader: cache_reader, publisher: event_publisher)
      allow(cache_reader).to receive(:read) do |now_ns:, **|
        { 'epoch' => 'observer', 'observed_monotonic_ns' => now_ns, 'coverage_started_ns' => ns(90),
          'records' => now_ns >= ns(115) ? [[1, 1, ns(100), ns(110), 0, ns(90), true]] : [], 'pending' => nil }
      end
      described_class.new(interval: 15, cpu_percent: 90, memory_percent: 95, load_multiplier: 2,
                          load_top: 2, restart_after_seconds: 90, stop_after_seconds: 600,
                          rtnl_watchdog: { 'enable' => false, 'latency_threshold_ms' => 2000 }, load_enable: false, dry_run: true,
                          watchdog:, workers:, host_load:, exposure:)
    end

    def exposure = controller.instance_variable_get(:@exposure)
    def publisher = exposure.instance_variable_get(:@publisher)

    it 'emits separately enabled collection in dry-run with neither gate active and never changes acute scores/actions' do
      observe(1, 100)
      observe(2, 115)
      expect(publisher).to have_received(:publish).with([
                                                          hash_including(opts: hash_including(segments: [hash_including(credit_us: 9_000_000)],
                                                                                              targets: [hash_including(qualification: 'qualified')]))
                                                        ])
      expect(score.restart_qualified_seconds).to eq(0)
      expect(score.stop_qualified_seconds).to eq(0)
      expect(permits).to be_empty
    end

    it 'validates the fixed exposure cutoff independently from a different disabled acute cutoff' do
      primary = { 'schema' => 1, 'boot_id' => File.read('/proc/sys/kernel/random/boot_id').strip,
                  'epoch' => 'observer', 'sequence' => 1, 'probe_sequence' => 1, 'state' => 'pending',
                  'observed_monotonic_ns' => ns(100), 'dispatch_monotonic_ns' => ns(99),
                  'started_monotonic_ns' => ns(99), 'completed_monotonic_ns' => nil,
                  'last_duration_ns' => nil, 'expected_errno' => 22, 'error_code' => 0,
                  'latency_run' => { 'version' => 1, 'valid' => true, 'cutoff_ns' => ns(1), 'interval_ns' => ns(1),
                                     'tick_ns' => ns(0.25), 'coverage_started_ns' => ns(90), 'slow_count' => 0,
                                     'first_probe' => nil, 'last_probe' => nil, 'first_started_ns' => nil, 'last_completed_ns' => nil } }
      validator = controller.instance_variable_get(:@exposure_watchdog)
      reader = exposure.instance_variable_get(:@reader)
      allow(validator).to receive(:read_frame) { primary.dup }
      controller.tick(now_ns: ns(100))
      primary['sequence'] += 1
      primary['observed_monotonic_ns'] += ns(0.25)
      controller.tick(now_ns: ns(100.25))
      expect(reader).to have_received(:read).with(now_ns: anything, watchdog: hash_including(epoch: 'observer'))
    end

    it 'does not advance exposure or publish from a rejected mandatory sample admission' do
      observe(1, 100)
      allow(evidence).to receive(:reserve).and_return(nil)
      allow(exposure).to receive(:observe).and_call_original
      expect(observe(2, 115)).to be(false)
      expect(exposure).not_to have_received(:observe)
      expect(publisher).to have_received(:publish).once
      expect(permits).to be_empty
    end
  end

  context 'with real persistent host history' do
    def initial_loads = [1.0, 1.0, 1.0]
    def history_file = (@history_file ||= File.join(Dir.mktmpdir('oomd-partial-history-'), 'host-load.yml'))
    let(:host_load) do
      stub_const('OsCtl::Oomd::HostLoad::STATE_FILE', history_file)
      File.write(history_file, OsCtl::Lib::ConfigFile.dump_yaml('version' => 2, 'loads' => initial_loads))
      OsCtl::Oomd::HostLoad.new(interval)
    end

    before { allow(host_load).to receive(:<<).and_call_original }
    after { FileUtils.remove_entry(File.dirname(history_file)) }

    def history = host_load.instance_variable_get(:@loads)
    def host_records = evidence_lines.map { |line| JSON.parse(line) }.select { |record| record['type'] == 'host' }

    def partial_observe(sequence, time, rows = [row], **changes)
      observe(sequence, time, rows, complete: false, invalid_reason: 'inventory_pending',
                                    inventory_complete: false, measurement_window_started_monotonic_ns: nil, **changes)
    end

    [5, 15].each do |rate|
      context "with interval #{rate}" do
        define_method(:interval) { rate }

        it 'advances valid host history through inventory and unrelated limit failures without crediting unknown targets' do
          unknown = row('b', cpu_limit: nil, loadavg: [0]).merge('cpu_limit_state' => 'unknown', 'errors' => { 'cpu_limit' => 'invalid_limit' })
          partial_observe(1, 100, [row, unknown], loadavg: [10])
          partial_observe(2, 100 + rate, [row, unknown], loadavg: [20], invalid_reason: 'invalid_limit')
          partial_observe(3, 100 + (2 * rate), [row, unknown], loadavg: [30])

          expect(history).to eq(initial_loads + [10, 20, 30])
          expect(host_records.map { |record| record['history_count'] }).to eq([4, 5, 6])
          expect(score.restart_qualified_seconds).to eq(rate)
          expect(controller.export.find { |ct| ct.id == 'b' }.restart_qualified_seconds).to eq(0)
          expect(permits).to be_empty
        end

        it 'appends each current point once across full and partial transitions' do
          observe(1, 100, loadavg: [10])
          partial_observe(2, 100 + rate, loadavg: [20])
          observe(3, 100 + (2 * rate), loadavg: [30])
          observe(4, 100 + (3 * rate), loadavg: [40])

          expect(history).to eq(initial_loads + [10, 20, 30, 40])
          expect(host_records.map { |record| record['history_median'] }).to eq([1.0, 1.0, 5.5, 10])
          expect(score.restart_qualified_seconds).to eq(3 * rate)
        end
      end
    end

    it 'rejects duplicates, stale samples, invalid host values and retired epochs without appending' do
      first = frame(1, 100)
      controller.observe(first, now_ns: ns(100))
      expect(controller.observe(first, now_ns: ns(101))).to be(false)
      expect(controller.observe(frame(2, 115), now_ns: ns(121))).to be(false)
      partial_observe(2, 115, loadavg: [Float::NAN])
      expect(history).to eq(initial_loads + [10])
      controller.child_started
      observe(1, 130, epoch: 'replacement')
      controller.child_started
      expect(observe(2, 145)).to be(false)
      expect(history).to eq(initial_loads + [10, 10])
      expect(permits).to be_empty
    end

    it 'keeps missing current host load unknown without advancing history' do
      observe(1, 100)
      data = frame(2, 115, complete: false, invalid_reason: 'invalid_host_value', measurement_window_started_monotonic_ns: nil)
      data['loadavg'] = data['containers'].last['loadavg'] = nil
      controller.observe(data, now_ns: ns(115))

      expect(history).to eq(initial_loads + [10])
      expect(score.restart_qualified_seconds).to eq(0)
      expect(permits).to be_empty
    end

    it 'rolls host history and scores back when expiry reservations cannot be admitted' do
      observe(1, 100)
      allow(controller).to receive(:reserve_expiries).and_return(nil)
      expect(partial_observe(2, 115)).to be(false)
      expect(history).to eq(initial_loads + [10])
      expect(score.restart_qualified_seconds).to eq(0)
      allow(controller).to receive(:reserve_expiries).and_call_original
      partial_observe(3, 130)
      expect(history).to eq(initial_loads + [10, 10])
      expect(score.restart_qualified_seconds).to eq(0)
    end

    it 'does not append under sample reservation pressure or backfill skipped samples' do
      held = evidence.reserve(300)
      expect(observe(1, 100)).to be(false)
      expect(history).to eq(initial_loads)
      evidence.release(held)
      partial_observe(3, 130)
      expect(history).to eq(initial_loads + [10])
      expect(permits).to be_empty
    ensure
      evidence.release(held)
    end

    context 'without established history' do
      def initial_loads = []

      it 'keeps the first partial transient, then commits both same-epoch cold points once' do
        partial_observe(1, 100, loadavg: [10])
        expect(history).to be_empty
        expect(host_records.last).to include('history_count' => 1, 'history_median' => nil, 'load_gate' => nil)
        partial_observe(2, 115, loadavg: [20])
        expect(history).to eq([10, 20])
        expect(host_records.last).to include('history_count' => 2, 'history_median' => 15.0, 'load_gate' => false)
        expect(score.restart_qualified_seconds).to eq(0)
      end

      it 'clears an unpromoted cold seed on a real child/epoch boundary' do
        partial_observe(1, 100, loadavg: [10])
        controller.child_started
        partial_observe(1, 115, loadavg: [100], epoch: 'replacement')
        expect(history).to be_empty
        partial_observe(2, 130, loadavg: [20], epoch: 'replacement')
        expect(history).to eq([100, 20])
        expect(permits).to be_empty
      end

      it 'preserves coherent full bootstrap and promotes a partial seed on full recovery' do
        seed(1, 100)
        observe(2, 115, loadavg: [20])
        expect(history).to eq([10, 20])
        expect(host_records.last['history_median']).to eq(15)
        expect(permits).to be_empty
      end

      it 'retains only the admitted cold seed after an oversized selected batch' do
        partial_observe(1, 100, loadavg: [10])
        controller.instance_variable_set(:@load_top, 400)
        expect(partial_observe(2, 115, Array.new(400) { |i| row(i.to_s) }, loadavg: [300])).to be(false)
        expect(history).to be_empty
        partial_observe(3, 130, loadavg: [20])
        expect(history).to eq([10, 20])
        expect(permits).to be_empty
      end

      it 'keeps the existing coherent full first-reading bootstrap' do
        observe(1, 100, loadavg: [10])
        expect(history).to eq([10])
        expect(host_records.last).to include('history_median' => 10, 'history_count' => 1)
        expect(score.restart_qualified_seconds).to eq(0)
      end
    end

    context 'with a dispatch median boundary' do
      def initial_loads = [0.0, 0.0]

      it 'uses the same single-inclusion median for evidence, scoring and final admission' do
        controller.instance_variable_set(:@restart_after_seconds, interval)
        partial_observe(1, 100, loadavg: [100])
        partial_observe(2, 115, loadavg: [300])
        partial_observe(3, 130, loadavg: [300])

        expect(history).to eq([0, 0, 100, 300, 300])
        expect(host_records.last).to include('history_median' => 100, 'history_count' => 5, 'load_gate' => true)
        expect(permits).to contain_exactly(include(action: :restart, run: [42, 123]))
      end
    end
  end

  context 'with optional partial-data diagnostics' do
    def logged(type) = evidence_lines.map { |line| JSON.parse(line) }.select { |record| record['type'] == type }

    def unknown_row(id = 'a', **changes)
      row(id, cpu_usage: nil, errors: { 'cpu_usage' => 'missing_cgroup_value' }, **changes)
    end

    def partial_sample(sequence, time, rows, **changes)
      observe(sequence, time, rows, complete: false, invalid_reason: 'inventory_pending', inventory_complete: false,
                                    measurement_window_started_monotonic_ns: nil, **changes)
    end

    def inventory_observation(time, status: 'pending')
      completion = { 'id' => 2, 'started_monotonic_ns' => ns(time - 25), 'completed_monotonic_ns' => ns(time - 20),
                     'duration_ns' => ns(5), 'result' => 'success' }
      { 'version' => 1, 'epoch' => 'sampler', 'observed_monotonic_ns' => ns(time),
        'request' => status && { 'id' => 3, 'started_monotonic_ns' => ns(time - 10), 'status' => status },
        'last_completion' => completion, 'last_success' => completion }
    end

    it 'records old, new and malformed optional observations without changing valid control' do
      observe(1, 100, loadavg: [300])
      expect(logged('host').last['inventory_observation']).to eq('status' => 'missing')
      ['pending', 'completed_unconsumed', nil].each_with_index do |status, i|
        time = 115 + (i * 15)
        observe(i + 2, time, loadavg: [300], inventory_observation: inventory_observation(time, status:))
        expect(logged('host').last['inventory_observation']).to include('status' => 'available', 'request' => status ? include('status' => status) : nil)
      end
      invalid = [nil, {}, { 'version' => 2 }, inventory_observation(145).merge('request' => false),
                 inventory_observation(160).merge('last_completion' => {}), inventory_observation(175).except('last_success')]
      invalid.each_with_index do |value, i|
        time = 160 + (i * 15)
        value = value.merge('observed_monotonic_ns' => ns(time)) if value.is_a?(Hash) && value['version'] == 1
        observe(i + 5, time, loadavg: [300], inventory_observation: value)
        expected = value == { 'version' => 2 } ? 'unsupported' : 'malformed'
        expect(logged('host').last['inventory_observation']).to eq('status' => expected)
      end
      expect(permits).to contain_exactly(include(action: :restart, run: [42, 123]))
    end

    it 'emits bounded four-target pages every30 accepted seconds for400unknown CTs with verbose enabled' do
      controller.instance_variable_set(:@verbose, true)
      rows = Array.new(400) { |i| unknown_row(format('%03d', i)) }
      5.times { |i| partial_sample(i + 1, 100 + (i * 15), rows) }
      pages = logged('unknown_targets')
      expect(pages.map { |page| page['entries'].map { |entry| entry['id'] } }).to eq([
                                                                                       %w[000 001 002 003], %w[004 005 006 007], %w[008 009 010 011]
                                                                                     ])
      expect(pages.map { |page| page['sample_sequence'] }).to eq([2, 4, 6])
      expect(logged('container')).to be_empty
      expect(logged('host')).to all(include('population' => 400, 'unknown_count' => 400, 'selected' => 0, 'selection' => 'none'))
      expect(evidence_lines.select { |line| JSON.parse(line)['type'] == 'unknown_targets' }.map(&:bytesize).max).to be <= 2048
      expect(evidence_lines.map(&:bytesize).max).to be <= 3072
      logged('sample_begin').each do |sample|
        lines = evidence_lines.select { |line| JSON.parse(line)['sample_sequence'] == sample['sample_sequence'] }
        expect(lines.size).to eq(sample['expected_lines'])
        expect(lines.size).to be <= 256
        expect(lines.sum(&:bytesize)).to be <= 1024 * 1024
      end
      expect(evidence.status).to include(evidence_records: 8)
    end

    it 'wraps over changed populations and restarts diagnostic cadence at a new sampler epoch' do
      partial_sample(1, 100, %w[a b c d e].map { |id| unknown_row(id) })
      partial_sample(2, 115, %w[a b c d e].map { |id| unknown_row(id) })
      partial_sample(3, 130, %w[a c e f].map { |id| unknown_row(id) })
      expect(logged('unknown_targets').last).to include('wrapped' => true)
      expect(logged('unknown_targets').last['entries'].map { |entry| entry['id'] }).to eq(%w[e f a c])
      controller.child_started
      partial_sample(1, 145, [unknown_row('z')], epoch: 'replacement')
      expect(logged('unknown_targets').last).to include('sample_epoch' => 'replacement', 'unknown_total' => 1)
    end

    it 'reports oversized identities by row reference and unrecognized errors by byte length' do
      rows = [unknown_row('a' * 5000), unknown_row('b', errors: { 'cpu_usage' => 'x' * 8000 }), unknown_row('c')]
      partial_sample(1, 100, rows)
      page = logged('unknown_targets').last
      expect(page).to include('considered' => 3, 'reported' => 2, 'unrepresentable' => 1)
      expect(page['entries'][0]).to eq('row_reference' => 0, 'unrepresented' => 'entry_exceeds_page_budget',
                                       'field_bytes' => { 'pool' => 4, 'id' => 5000 })
      expect(page['entries'][1]).to include('id' => 'b', 'errors' => [['cpu_usage', 'unrecognized_error', 8000]])
      expect(JSON.generate(page)).not_to include('a' * 100, 'x' * 100)
      expect(controller.status[:evidence_paused]).to eq(0)
    end

    it 'defers diagnostics when mandatory records fill the batch and retries without pausing' do
      controller.instance_variable_set(:@load_top, 400)
      rows = Array.new(253) { |i| row("q#{i}") } + [unknown_row('z')]
      partial_sample(1, 100, rows)
      expect(logged('sample_begin').last).to include('expected_lines' => 256, 'unknown_diagnostic' => include('status' => 'deferred', 'considered' => 0))
      expect(logged('unknown_targets')).to be_empty
      expect(controller.status[:evidence_paused]).to eq(0)
      partial_sample(2, 115, [unknown_row('z')])
      expect(logged('unknown_targets').last['entries'].map { |entry| entry['id'] }).to eq(['z'])
    end

    it 'selects against spare byte headroom before generating optional pages' do
      stub_const('OsCtl::Oomd::Evidence::SAMPLE_BYTES', 8192)
      partial_sample(1, 100, [unknown_row])
      expect(logged('unknown_targets')).to be_empty
      expect(logged('sample_begin').last['unknown_diagnostic']).to include('status' => 'deferred')
      expect(controller.status[:evidence_paused]).to eq(0)
      stub_const('OsCtl::Oomd::Evidence::SAMPLE_BYTES', 1024 * 1024)
      partial_sample(2, 115, [unknown_row])
      expect(logged('unknown_targets').size).to eq(1)
    end

    it 'commits neither diagnostic cursor nor cadence when sample admission fails' do
      rows = %w[a b c d e f g h].map { |id| unknown_row(id) }
      partial_sample(1, 100, rows)
      partial_sample(2, 115, rows)
      allow(controller).to receive(:reserve_expiries).and_return(nil)
      expect(partial_sample(3, 130, rows)).to be(false)
      expect(logged('unknown_targets').size).to eq(1)
      allow(controller).to receive(:reserve_expiries).and_call_original
      partial_sample(4, 145, rows)
      expect(logged('unknown_targets').last['entries'].map { |entry| entry['id'] }).to eq(%w[e f g h])
    end

    it 'moves inventory detail to the bounded optional page when the host record has no room' do
      controller.instance_variable_get(:@settings)['state_file'] = "/#{'p' * 2000}"
      partial_sample(1, 100, [unknown_row], inventory_observation: inventory_observation(100))
      expect(logged('sample_begin').last['unknown_diagnostic']).to include('inventory_detail' => 'page', 'inventory_status' => 'available')
      expect(logged('unknown_targets').last['inventory_observation']).to include('status' => 'available')
      expect(evidence_lines.select { |line| JSON.parse(line)['type'] == 'unknown_targets' }.first.bytesize).to be <= 2048
    end
  end

  it 'emits pre-gate qualifiers with both gates disabled independent of verbose' do
    actor = described_class.new(interval:, cpu_percent: 90, memory_percent: 95, load_multiplier: 2,
                                load_top: 2, restart_after_seconds: 90, stop_after_seconds: 600,
                                load_enable: false, rtnl_watchdog: {}, workers:, host_load:, watchdog:, verbose: false)
    actor.child_started
    expect(actor.observe(frame(1, 100), now_ns: ns(100))).to be(true)
    Timeout.timeout(2) { Thread.pass until evidence.status[:evidence_pending_records] == 0 }
    records = evidence_lines.map { |line| JSON.parse(line) }
    expect(records.map { |r| r['type'] }).to eq(%w[sample_begin host container sample_end])
    expect(records[1]).to include('load_enable' => false, 'rtnl_enable' => false)
    expect(records[2]).to include('qualified' => true, 'restart_after' => 0.0, 'load_gate' => false)
    expect(watchdog).to have_received(:episode)
    expect(permits).to be_empty
  end

  it 'emits closed-gate host evidence with400idle CTs and verbose=true without idle row flooding' do
    actor = described_class.new(interval:, cpu_percent: 90, memory_percent: 95, load_multiplier: 2,
                                load_top: 2, restart_after_seconds: 90, stop_after_seconds: 600,
                                rtnl_watchdog: {}, workers:, host_load:, watchdog:, verbose: true)
    actor.child_started
    rows = Array.new(400) { |i| row(i.to_s, memory: 1, cpu_usage: 1) }
    expect(actor.observe(frame(1, 100, rows), now_ns: ns(100))).to be(true)
    Timeout.timeout(2) { Thread.pass until evidence.status[:evidence_pending_records] == 0 }
    records = evidence_lines.map { |line| JSON.parse(line) }
    expect(records.map { |r| r['type'] }).to eq(%w[sample_begin host sample_end])
    expect(records[1]).to include('population' => 400, 'selected' => 0, 'selection' => 'none', 'excluded_count' => 400)
  end

  it 'pauses an oversized sample before score commit then resumes without backlog credit' do
    observe(1, 100, loadavg: [300])
    observe(2, 115, loadavg: [300])
    expect(score.restart_qualified_seconds).to eq(15)
    controller.instance_variable_set(:@load_top, 400)
    too_many = Array.new(400) { |i| row(i.to_s) }
    expect(controller.observe(frame(3, 130, too_many, loadavg: [300]), now_ns: ns(130))).to be(false)
    expect(score.restart_qualified_seconds).to eq(15)
    expect(controller.status[:evidence_paused]).to eq(1)
    observe(4, 145, loadavg: [300])
    expect(score.restart_qualified_seconds).to eq(0) # U elapsed while paused.
    expect(permits).to be_empty
    records = evidence_lines.map { |line| JSON.parse(line) }
    expect(records).to include(include('type' => 'score_expired', 'restart_before' => 15.0))
    expect(records).to include(include('type' => 'evidence_paused', 'reason' => 'sample_oversize'))
    expect(records).to include(include('type' => 'evidence_resumed', 'omitted_count' => 1))
    expect(records.select { |r| r['sample_sequence'] == 4 && r['type'] == 'sample_begin' }).to be_empty
  end

  it 'emits the first sampler-loss marker before recovery without repetitive invalid-frame records' do
    observe(1, 100, loadavg: [300])
    controller.invalidate
    controller.invalidate
    Timeout.timeout(2) { Thread.pass until evidence.status[:evidence_pending_records] == 0 }
    records = evidence_lines.map { |line| JSON.parse(line) }
    expect(records.count { |record| record['type'] == 'evidence_paused' }).to eq(1)
    expect(controller.status[:evidence_paused]).to eq(1)
    expect(records.none? { |record| record['type'] == 'evidence_resumed' }).to be(true)
  end

  it 'keeps reserved expiry and received actions live while sample admission is blocked' do
    observe(1, 100, loadavg: [300])
    observe(2, 115, loadavg: [300])
    held = evidence.reserve(300)
    expect(controller.observe(frame(3, 130, loadavg: [300]), now_ns: ns(130))).to be(false)
    expect(score.restart_qualified_seconds).to eq(15)
    controller.tick(now_ns: ns(145))
    expect(score.restart_qualified_seconds).to eq(0)
    Timeout.timeout(2) { Thread.pass until evidence.status[:evidence_pending_records] == 0 }
    records = evidence_lines.map { |line| JSON.parse(line) }
    expect(records).to include(include('type' => 'score_expired'))
    expect(controller.status[:evidence_paused]).to eq(1)
    evidence.release(held)
    observe(4, 145, loadavg: [300])
    expect(score.restart_qualified_seconds).to eq(0)
  ensure
    evidence.release(held)
  end

  [1, 5, 15].each do |rate|
    context "with interval #{rate}" do
      define_method(:interval) { rate }

      it 'seeds first, then requires90 covered seconds without CPU bypass' do
        enter_episode(99)
        (90 / rate).times { |i| observe(i + 1, 100 + (i * rate)) }
        expect(permits).to be_empty
        expect(score.restart_qualified_seconds).to eq(90 - rate)
        observe((90 / rate) + 1, 190)
        expect(permits).to contain_exactly(include(action: :restart, run: [42, 123]))
      end

      it 'accepts exactly interval+5 of linked CPU coverage and caps its credit at interval' do
        observe(1, 100, loadavg: [300])
        t = 100 + rate + 4.9
        expect(observe(2, t, measurement_window_started_monotonic_ns: ns(99.9), loadavg: [300])).to be(true)
        expect(score.restart_qualified_seconds).to eq(rate)
        expect(permits).to be_empty
      end

      it 'rejects a window beyond interval+5 and does not grant backlog on recovery' do
        observe(1, 100, loadavg: [300])
        observe(2, 100 + rate, loadavg: [300])
        saved = score.restart_qualified_seconds
        expect(observe(3, 100 + (2 * rate), measurement_window_started_monotonic_ns: ns(100 + rate - 5.1) - 1)).to be(false)
        observe(4, 100 + (3 * rate), loadavg: [300])
        expect(score.restart_qualified_seconds).to eq(rate == 15 ? 0 : saved)
        expect(permits).to be_empty
      end
    end
  end

  it 'keeps both disabled gates inactive without dispatch or stop scoring' do
    actor = described_class.new(interval: 15, cpu_percent: 90, memory_percent: 95, load_multiplier: 2,
                                load_top: 2, restart_after_seconds: 90, stop_after_seconds: 600,
                                load_enable: false, rtnl_watchdog: {}, workers:, host_load:)
    actor.child_started
    20.times do |i|
      expect(actor.observe(frame(i + 1, 100 + (15 * i), loadavg: [300]), now_ns: ns(100 + (15 * i)))).to be(true)
    end
    expect(permits).to be_empty
    expect(actor.export.all? { |ct| ct.stop_qualified_seconds == 0 }).to be(true)
  end

  it 'retains ordinary same-run credit across RTNL epoch/healthy changes' do
    5.times { |i| observe(i + 1, 100 + (15 * i), loadavg: [300]) }
    expect(score.restart_qualified_seconds).to eq(60)
    enter_episode(161)
    observe(6, 175, loadavg: [300])
    expect(score.restart_qualified_seconds).to eq(75)
    allow(watchdog).to receive(:episode).and_return(nil)
    controller.tick(now_ns: ns(176))
    expect(score.restart_qualified_seconds).to eq(75)
    observe(7, 190, loadavg: [300])
    expect(permits.size).to eq(1)
  end

  it 'never grants on both gates disabled or low CPU even under RTNL activation' do
    enter_episode(99)
    8.times { |i| observe(i + 1, 100 + (15 * i), [row(cpu_usage: 20)]) }
    expect(permits).to be_empty
    expect(score.restart_qualified_seconds).to eq(0)
    allow(watchdog).to receive(:episode).and_return(nil)
    8.times { |i| observe(i + 9, 220 + (15 * i)) }
    expect(permits).to be_empty
  end

  it 'does not credit partial targets with unknown CPU or unknown rank' do
    enter_episode(99)
    seed(1, 100)
    invalid = row(cpu_usage: nil, errors: { 'cpu_usage' => 'missing_cgroup_value' })
    observe(2, 115, [invalid], complete: false, invalid_reason: 'missing_cgroup_value', measurement_window_started_monotonic_ns: nil)
    expect(score.restart_qualified_seconds).to eq(0)
    expect(permits).to be_empty
  end

  it 'keeps ordinary time usable while RTNL data are unknown' do
    allow(watchdog).to receive(:diagnostic).and_return('unavailable')
    4.times { |i| observe(i + 1, 100 + (15 * i), loadavg: [300]) }
    expect(score.restart_qualified_seconds).to eq(45)
    expect(score.last_usable_ns).to eq(ns(145))
    expect(permits).to be_empty
  end

  it 'expires unknown restart evidence without discarding stop history' do
    observe(1, 100, loadavg: [300])
    observe(2, 115, loadavg: [300])
    expect(score.restart_qualified_seconds).to eq(15)
    controller.invalidate
    controller.tick(now_ns: ns(145))
    expect(score.restart_qualified_seconds).to eq(0)
    expect(score.stop_qualified_seconds).to eq(15)
  end

  it 'retains reservations indefinitely after unknown effects' do
    enter_episode(99)
    7.times { |i| observe(i + 1, 100 + (15 * i)) }
    permit = permits.fetch(0)
    allow(workers).to receive(:completions).and_yield(permit, :unknown)
    controller.tick(now_ns: ns(191))
    allow(workers).to receive(:completions)
    controller.tick(now_ns: ns(1000))
    expect(controller.inflight.fetch(%w[tank a])).to eq(permit)
    expect(controller.status[:unknown_actions]).to eq(1)
    expect(permits.size).to eq(1)
  end

  it 'preserves load-only stop seconds across successful restarts and gives stop priority' do
    actor = described_class.new(interval: 15, cpu_percent: 90, memory_percent: 95, load_multiplier: 2,
                                load_top: 2, restart_after_seconds: 30, stop_after_seconds: 60,
                                rtnl_watchdog: {}, workers:, host_load:)
    actor.child_started
    3.times { |i| actor.observe(frame(i + 1, 100 + (15 * i), loadavg: [300]), now_ns: ns(100 + (15 * i))) }
    first = permits.fetch(0)
    expect(first[:action]).to eq(:restart)
    allow(workers).to receive(:completions).and_yield(first, :success)
    actor.tick(now_ns: ns(131))
    allow(workers).to receive(:completions)
    3.times { |i| actor.observe(frame(i + 4, 145 + (15 * i), loadavg: [300]), now_ns: ns(145 + (15 * i))) }
    expect(permits.last[:action]).to eq(:stop)
  end

  it 'revalidates the RTNL gate immediately before enqueue without freeing a permit' do
    enter_episode(99)
    6.times { |i| observe(i + 1, 100 + (15 * i)) }
    allow(watchdog).to receive(:episode).and_return(['watchdog', 1], nil)
    observe(7, 190)
    expect(permits).to be_empty
  end

  [false, true].product(%i[restart stop]).each do |enabled, action|
    it "simulates #{action} without executor or real success event (RTNL enabled: #{enabled})" do
      executed = Queue.new
      events = Queue.new
      actual_workers = OsCtl::Oomd::ActionWorkers.new(size: 1, dry_run: true, evidence: OsCtl::Oomd::Evidence.new(writer: lambda { |bytes|
        evidence_lines << bytes
        bytes.bytesize
      }),
                                                      executor: lambda { |permit|
                                                        executed << permit
                                                        true
                                                      },
                                                      notifier: ->(event) { events << event })
      actor = described_class.new(interval:, cpu_percent: 90, memory_percent: 95, load_multiplier: 2,
                                  load_top: 2, restart_after_seconds: 15, stop_after_seconds: action == :stop ? 15 : 600,
                                  rtnl_watchdog: { 'enable' => enabled }, watchdog:, workers: actual_workers, host_load:)
      allow(watchdog).to receive(:episode).and_return(['probe', 1]) if enabled
      actor.start
      actor.child_started
      actor.tick(now_ns: ns(99))
      load = enabled && action == :restart ? 100 : 300
      [100, 115].each_with_index do |time, i|
        expect(actor.observe(frame(i + 1, time, loadavg: [load]), now_ns: ns(time))).to be(true)
      end
      permit = actor.inflight.fetch(%w[tank a])
      expect(permit).to include(action:, run: [42, 123], sequence: 3)
      Timeout.timeout(1) do
        until actor.inflight.empty?
          actor.tick(now_ns: ns(116))
          Thread.pass
        end
      end
      expect(actor.export.first.restart_qualified_seconds).to eq(0)
      preserved = action == :restart && !enabled ? 15 : 0
      expect(actor.export.first.stop_qualified_seconds).to eq(preserved)
      expect(actual_workers.dispatch(permit.merge(id: 'slot-probe'))).to be(true)
      actor.stop
      actor = nil
      expect(executed).to be_empty
      notices = Array.new(events.size) { events.pop }
      expect(notices).to be_empty
      records = evidence_lines.map { |line| JSON.parse(line, symbolize_names: true) }
      expect(records).to include(include(type: 'action_result', result: 'simulated', message: /would #{action} tank:a.*result=simulated/))
    ensure
      actor&.stop
    end
  end

  [0, 1].each do |over_ns|
    it "checks full grant freshness after building the permit (deadline + #{over_ns}ns)" do
      enter_episode(99)
      6.times { |i| observe(i + 1, 100 + (15 * i)) }
      trace = []
      ticks = 0
      elapsed = 0
      allow(controller).to receive(:tick).and_wrap_original do |tick, **args|
        ticks += 1
        tick.call(**args)
      end
      allow(controller).to receive(:monotonic_ns) do
        trace << :clock
        elapsed
      end
      allow(Time).to receive(:now).and_wrap_original do |clock|
        if ticks == 2
          trace << :permit_time
          elapsed = ns(5) + over_ns
        end
        clock.call
      end
      allow(workers).to receive(:dispatch) do |permit|
        trace << :dispatch
        permits << permit
        true
      end

      expect(observe(7, 190)).to be(true)
      expect(trace).to eq(%i[clock clock permit_time clock] + (over_ns == 0 ? [:dispatch] : []))
      expect(score.stop_qualified_seconds).to eq(0)
      expect(host_load).to have_received(:<<).with(10).exactly(7).times
      if over_ns == 0
        expect(permits).to contain_exactly(include(action: :restart, sequence: 8, run: [42, 123]))
        expect(controller.inflight.values).to eq(permits)
      else
        expect(permits).to be_empty
        expect(controller.inflight).to be_empty
        expect(score.restart_qualified_seconds).to eq(90)
        expect(permits).to be_empty
      end
    end
  end

  [0, 1].each do |over_ns|
    it "counts a clock jump at default observation entry (deadline + #{over_ns}ns)" do
      enter_episode(99)
      6.times { |i| observe(i + 1, 100 + (15 * i)) }
      # Do not inject now_ns: time between method entry and final grant counts.
      allow(controller).to receive(:monotonic_ns).and_return(ns(190), ns(195) + over_ns)
      expect(controller.observe(frame(7, 190))).to be(true)

      if over_ns == 0
        expect(permits).to contain_exactly(include(action: :restart, sequence: 8))
        expect(controller.inflight.values).to eq(permits)
      else
        expect(permits).to be_empty
        expect(controller.inflight).to be_empty
        expect(score.restart_qualified_seconds).to eq(90)
      end
    end
  end

  it 'requires the generic schema and rewarms after rejecting the replaced oomd schema' do
    expect(controller.observe(frame(1, 100, top_schema: nil, oomd_schema: 1), now_ns: ns(100))).to be(false)
    expect(observe(1, 100)).to be(false)
    expect(observe(2, 115)).to be(true)
    expect(score.restart_qualified_seconds).to eq(0)
    expect(permits).to be_empty
  end

  it 'requires all three typed effective collectors to be disabled' do
    invalid = [nil, {}, { 'netif' => false, 'zfs' => false }]
    %w[netif zfs iostat].each do |key|
      [true, nil, 0, 'false'].each do |value|
        invalid << { 'netif' => false, 'zfs' => false, 'iostat' => false }.merge(key => value)
      end
    end
    invalid.each { |collectors| expect(observe(1, 100, collectors:)).to be(false) }
    expect(observe(1, 100)).to be(false)
    expect(observe(2, 115)).to be(true)
    expect(permits).to be_empty
  end

  it 'accepts independent sweep and age budgets at the full CPU envelope boundary' do
    data = frame(1, 100, sample_started_monotonic_ns: ns(95), measurement_window_started_monotonic_ns: ns(80))
    expect(controller.observe(data, now_ns: ns(105))).to be(true)
    expect(permits).to be_empty
  end

  it 'rejects overlong sweeps, aged completions and incoherent full CPU envelopes' do
    invalid = [
      { sample_started_monotonic_ns: ns(95) - 1 },
      { measurement_window_started_monotonic_ns: ns(80) - 1 },
      { measurement_window_started_monotonic_ns: ns(99.9) },
      { measurement_window_started_monotonic_ns: nil },
      { measurement_window_completed_monotonic_ns: ns(100) - 1 }
    ]
    invalid.each { |changes| expect(observe(1, 100, **changes)).to be(false) }
    expect(controller.observe(frame(1, 100), now_ns: ns(105) + 1)).to be(false)
    expect(permits).to be_empty
  end

  it 'rejects header-only sampler changes and retired epochs after a real child boundary' do
    enter_episode(99)
    observe(1, 100)
    expect(observe(2, 115, epoch: 'replacement')).to be(false)
    controller.child_started
    expect(observe(1, 130, epoch: 'replacement')).to be(true)
    expect(score.restart_qualified_seconds).to eq(0)
    controller.child_started
    expect(observe(2, 145)).to be(false)
    expect(score.restart_qualified_seconds).to eq(0)
    expect(permits).to be_empty
  end

  it 'does not carry old-run seconds to a replacement init' do
    enter_episode(99)
    6.times { |i| observe(i + 1, 100 + (15 * i)) }
    expect(score.restart_qualified_seconds).to eq(75)
    seed(7, 190, [row(init_start_time_ticks: 124)])
    observe(8, 205, [row(init_start_time_ticks: 124)])
    expect(score.restart_qualified_seconds).to eq(0)
    expect(permits).to be_empty
    observe(9, 220, [row(init_start_time_ticks: 124)])
    expect(score.restart_qualified_seconds).to eq(15)
  end

  it 'deduplicates in-flight targets and seeds fresh evidence after a definitive failed action' do
    enter_episode(99)
    7.times { |i| observe(i + 1, 100 + (15 * i)) }
    observe(8, 205)
    expect(permits.size).to eq(1)
    permit = permits.first
    allow(workers).to receive(:completions).and_yield(permit, :failed)
    controller.tick(now_ns: ns(206))
    expect(controller.inflight).to be_empty
    allow(workers).to receive(:completions)
    observe(9, 220)
    expect(score.restart_qualified_seconds).to eq(0)
    expect(permits.size).to eq(1)
  end

  it 'does not retry a retained candidate when a busy physical slot becomes free' do
    enter_episode(99)
    allow(workers).to receive(:dispatch).and_return(false)
    7.times { |i| observe(i + 1, 100 + (15 * i)) }
    expect(controller.inflight).to be_empty
    allow(workers).to receive(:dispatch) { |permit|
      permits << permit
      true
    }
    controller.tick(now_ns: ns(191))
    expect(permits).to be_empty
    observe(8, 205, [row(memory: 20)])
    expect(permits).to be_empty
  end

  it 'rejects replayed acquisition time after processing made a full grant stale' do
    enter_episode(99)
    6.times { |i| observe(i + 1, 100 + (15 * i)) }
    allow(controller).to receive(:monotonic_ns).and_return(0, ns(6))
    observe(7, 190)
    expect(score.restart_qualified_seconds).to eq(90)
    expect(permits).to be_empty
    expect(observe(8, 190)).to be(false)
    expect(score.anchor_ns).to be_nil
    expect(permits).to be_empty
  end
end
