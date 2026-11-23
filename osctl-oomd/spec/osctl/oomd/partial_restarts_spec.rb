# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe OsCtl::Oomd::Controller, '#observe' do
  let(:watchdog_enabled) { false }
  let(:restart_hits) { 2 }
  let(:stop_hits) { 40 }
  let(:controller) { make_controller }
  let(:load_top) { 2 }

  def fixture
    JSON.parse(File.read(File.join(REPO_ROOT, 'osctl/spec/osctl/cli/top/fixtures/observation_memory_failure.json')))
  end

  attr_reader :permits, :loads, :watchdog, :host_load, :workers

  def make_controller
    described_class.new(interval: 15, cpu_percent: 90, memory_percent: 95, load_multiplier: 2,
                        load_top:, restart_hits:, stop_hits:,
                        rtnl_watchdog: { 'enable' => watchdog_enabled }, workers:, host_load:, watchdog:)
  end

  def ns(seconds) = (seconds * 1_000_000_000).to_i

  def frame(sequence, reason: nil, epoch: 'fixture-e')
    started = ns(100 + ((sequence - 6) * 15))
    completed = started + ns(0.2)
    previous = started - ns(15)
    raw = fixture.merge('memory' => { 'used' => 1_500_000_000 }, 'cpu' => { 'user' => 20 })
    raw.update('epoch' => epoch, 'sequence' => sequence, 'sample_started_monotonic_ns' => started,
               'sample_completed_monotonic_ns' => completed, 'previous_sample_started_monotonic_ns' => previous,
               'measurement_window_started_monotonic_ns' => reason.nil? ? previous : nil,
               'measurement_window_completed_monotonic_ns' => completed, 'complete' => reason.nil?, 'invalid_reason' => reason)
    raw['containers'][0..1].each do |row|
      row.update('cpu_baseline_sequence' => sequence - 1, 'cpu_window_started_monotonic_ns' => previous, 'errors' => {})
    end
    if reason == 'missing_cgroup_value'
      raw['containers'][1]['errors']['memory'] = reason
    else
      raw['containers'][1]['memory'] = 250_000_000
    end
    raw
  end

  def observe(raw, now: raw.fetch('sample_completed_monotonic_ns'))
    controller.observe(raw, now_ns: now)
  end

  def score(id = '101') = controller.export.find { |ct| ct.id == id }

  before do
    @permits = []
    @loads = []
    @watchdog = instance_double(OsCtl::Oomd::WatchdogState, episode: nil)
    @host_load = instance_double(OsCtl::Oomd::HostLoad, median: 5, median_with: 5, established?: true)
    @workers = instance_double(OsCtl::Oomd::ActionWorkers, publish: true, completions: nil, notification_drops: 0, notification_failures: 0)
    allow(host_load).to receive(:<<) { |load| loads << load }
    allow(workers).to receive(:dispatch) do |permit|
      permits << permit
      true
    end
    controller.child_started
  end

  it 'counts both scores for the verified target on the shared partial frame' do
    expect(observe(frame(6))).to be(true)
    expect(score.stop_hits).to eq(1)
    expect(observe(fixture)).to be(true)
    expect(permits).to contain_exactly(include(action: :restart, pool: 'tank', id: '101', run: [201, 12_345], sequence: 7))
    expect(score.stop_hits).to eq(2)
    expect(score('102').restart_hits).to eq(0)
    expect(loads).to eq([20.0])
    expect(watchdog).not_to have_received(:episode)
  end

  it 'does not manufacture a partial hit from an unobserved seed or unestablished ordinary history' do
    allow(host_load).to receive_messages(established?: false, median_with: nil)
    allow(host_load).to receive(:cold_median_with).and_return(nil, 20, 20)
    expect(observe(fixture)).to be(false)
    expect(observe(frame(8, reason: 'missing_cgroup_value'))).to be(true)
    expect(observe(frame(9, reason: 'missing_cgroup_value'))).to be(true)
    expect(score.restart_hits).to eq(0)
    expect(loads).to be_empty
    expect(permits).to be_empty
  end

  it 'rejects old, wrapped and contradictory full observations' do
    full = frame(8)
    expect(observe(full.merge('top_schema' => 1))).to be(false)
    expect(observe(full.merge('observation' => full))).to be(false)
    full['containers'][0]['errors']['memory'] = 'missing_cgroup_value'
    expect(observe(full)).to be(false)
    expect(loads).to be_empty
    expect(permits).to be_empty
  end

  it 'lets the cold node detect a measured spike without persisting partial history' do
    Dir.mktmpdir('oomd-cold-') do |dir|
      state = File.join(dir, 'history.yml')
      stub_const('OsCtl::Oomd::HostLoad::STATE_FILE', state)
      @host_load = OsCtl::Oomd::HostLoad.new(15)
      actor = described_class.new(interval: 15, cpu_percent: 90, memory_percent: 95, load_multiplier: 2,
                                  load_top: 5, restart_hits: 8, stop_hits: 40, rtnl_watchdog: {}, workers:, host_load:)
      loads_input = ([1.0] * 10) + ([8.0] * 8)
      loads_input.each_with_index do |load, i|
        raw = frame(6 + i, reason: 'missing_cgroup_value')
        raw['loadavg'] = raw['containers'].last['loadavg'] = [load, 0.0, 0.0]
        actor.observe(raw, now_ns: raw.fetch('sample_completed_monotonic_ns'))
        expect(permits).to be_empty if i < loads_input.size - 1
      end
      expect(permits).to contain_exactly(include(action: :restart, sequence: 23))
      expect(host_load).not_to be_established
      expect(File).not_to exist(state)
      expect(actor.export.find { |ct| ct.id == '101' }.stop_hits).to eq(8)

      seed = frame(24, reason: 'initial_baseline')
      actor.observe(seed, now_ns: seed.fetch('sample_completed_monotonic_ns'))
      full = frame(25)
      expect(actor.observe(full, now_ns: full.fetch('sample_completed_monotonic_ns'))).to be(true)
      expect(host_load.median).to eq(20.0)
      expect(OsCtl::Lib::ConfigFile.load_yaml_file(state)).to eq('version' => 2, 'loads' => [20.0])
      expect(actor.export.find { |ct| ct.id == '101' }.stop_hits).to eq(8)
    end
  end

  it 'keeps full ranking ties in wire order, and scores hits and misses on both counters' do
    [6, 7, 8].zip([1, 0, 1]).each do |sequence, expected|
      data = frame(sequence)
      a, b, host = data['containers']
      a['loadavg'] = b['loadavg'] = [host['loadavg'][0] - 1, 0, 0]
      data['containers'] = [b, a, host] if sequence == 7
      expect(observe(data)).to be(true)
      expect([score.restart_hits, score.stop_hits]).to eq([expected, expected])
    end
    expect(loads).to eq([20.0] * 3)
    expect(permits).to be_empty
  end

  it 'keeps hard invalid, subsequent good seed and eligible full decisions distinct' do
    observe(frame(6))
    observe(fixture)
    expect(observe(frame(8))).to be(true) # only per-run pairs are usable at this point
    expect(observe(frame(9, reason: 'initial_baseline'))).to be(true)
    expect(observe(frame(10))).to be(true)
    expect(loads).to eq([20.0, 20.0])
    expect(score.stop_hits).to eq(2)
  end

  it 'cannot use an absent ranking peer, bad mask, a stale packet or an old epoch as evidence' do
    observe(frame(6))
    data = Marshal.load(Marshal.dump(fixture))
    data['containers'][1]['loadavg'] = nil
    expect(observe(data)).to be(true) # structurally valid, but A cannot prove rank 2
    next_frame = frame(8, reason: 'missing_cgroup_value')
    expect(observe(next_frame, now: next_frame['sample_completed_monotonic_ns'] + ns(5) + 1)).to be(false)
    data = frame(9, reason: 'missing_cgroup_value')
    data['collectors']['zfs'] = 'false'
    expect(observe(data)).to be(false)
    expect(observe(frame(10, reason: 'initial_baseline', epoch: 'new-sampler'))).to be(false)
    expect(observe(frame(11))).to be(false)
    expect(permits).to be_empty
    expect(score.stop_hits).to eq(1)
    expect(loads).to eq([20.0])
  end

  [
    { 'cpu_baseline_sequence' => 4 },
    { 'cpu_window_started_monotonic_ns' => 0 },
    { 'group_path' => 'replacement/path' },
    { 'init_start_time_ticks' => 35_000 },
    { 'memory_limit' => nil, 'memory_limit_state' => 'unknown' },
    { 'cpu_limit' => nil, 'cpu_limit_state' => 'unknown' },
    { 'cpu_usage' => 10**400 },
    { 'cpu_usage' => 1e300, 'cpu_limit' => 1e-300 },
    { 'cpu_usage' => nil, 'cpu_baseline_sequence' => nil, 'cpu_window_started_monotonic_ns' => nil,
      'errors' => { 'cpu_usage' => 'invalid_host_cpu_delta' } }
  ].each_with_index do |fields, i|
    it "rejects unsafe target data variant #{i + 1} (#{fields.keys.join(', ')})" do
      observe(frame(6))
      raw = fixture
      raw['containers'][0].update(fields)
      observe(raw)
      expect(permits).to be_empty
      expect(score.stop_hits).to eq(1)
      expect(loads).to eq([20.0])
    end
  end

  it 'isolates an unrelated CPU window mismatch to that container' do
    observe(frame(6))
    raw = fixture
    raw['containers'][1]['cpu_baseline_sequence'] -= 1
    expect(observe(raw)).to be(true)
    expect(permits).to contain_exactly(include(action: :restart, id: '101', sequence: 7))
    expect(score('102').stop_hits).to eq(0)
  end

  it 'rejects contradictory membership, duplicate rows, future completion and overlap' do
    observe(frame(6))
    next_frame = frame(7, reason: 'missing_cgroup_value')
    next_frame['state_counts']['running'] = 3
    expect(observe(next_frame)).to be(false)
    next_frame['containers'].insert(-2, next_frame['containers'][0].dup)
    expect(observe(next_frame)).to be(false)
    expect(observe(fixture, now: fixture['sample_completed_monotonic_ns'] - 1)).to be(false)
    next_frame = frame(7, reason: 'initial_baseline')
    next_frame['sample_started_monotonic_ns'] = ns(100) + 1
    next_frame['sample_completed_monotonic_ns'] = ns(100.2) + 1
    next_frame['measurement_window_completed_monotonic_ns'] = ns(100.2) + 1
    next_frame['previous_sample_started_monotonic_ns'] = ns(100)
    expect(observe(next_frame)).to be(false)
    expect(permits).to be_empty
  end

  it 're-seeds after a bad frame or delivery gap without scoring the first good raw sweep' do
    observe(frame(6))
    expect(controller.observe({}, now_ns: ns(110))).to be(false)
    expect(observe(frame(8))).to be(false)
    expect(observe(frame(9))).to be(true)
    expect(permits).to contain_exactly(include(action: :restart, sequence: 9))
    expect(loads).to eq([20.0, 20.0])
  end

  describe 'recovery through the child reader and mailbox' do
    [[:malformed, false], [:malformed, true], [:overwritten, false], [:wrong_mask, true]].each do |damage, separate_tick|
      it "does not bootstrap past #{damage} on the replacement child (separate tick: #{separate_tick})" do
        mailbox = OsCtl::Oomd::Watcher::Mailbox.new
        sampler = OsCtl::Oomd::CtTop.new(15)
        deliver = lambda do |*records|
          lines = records.map { |record| record.is_a?(Hash) ? JSON.generate(record) : record }
          sampler.send(:read_child, StringIO.new("#{lines.join("\n")}\n")) { |item| mailbox.push(item) }
        end
        mailbox.push(:child_started)
        deliver.call(frame(6))
        expect(mailbox.drain(controller, now_ns: ns(100.2))).to be(true)
        mailbox.push({}) # Old child's EOF, followed by an actual spawn signal.
        mailbox.push(:child_started)
        first = frame(7, epoch: 'replacement')
        bad = case damage
              when :malformed then '{'
              when :wrong_mask then first.merge('collectors' => {})
              else first
              end
        deliver.call(bad)
        mailbox.drain(controller, now_ns: ns(115.2)) if separate_tick
        seed = frame(8, epoch: 'replacement')
        deliver.call(seed)
        expect(mailbox.drain(controller, now_ns: seed.fetch('sample_completed_monotonic_ns'))).to be(false)
        expect(loads).to eq([20.0])
        expect([score.restart_hits, score.stop_hits]).to eq([1, 1])
        expect(permits).to be_empty
        deliver.call(frame(9, epoch: 'replacement'))
        expect(mailbox.drain(controller, now_ns: ns(145.2))).to be(true)
        expect(loads).to eq([20.0, 20.0])
        expect(permits).to contain_exactly(include(epoch: 'replacement', sequence: 9))
      end
    end

    it 'admits a clean replacement even when the preceding EOF coalesces with it' do
      mailbox = OsCtl::Oomd::Watcher::Mailbox.new
      observe(frame(6))
      mailbox.push({})
      mailbox.push(:child_started)
      data = frame(7, epoch: 'replacement')
      2.times { mailbox.push(data.dup) }
      expect(mailbox.drain(controller, now_ns: ns(115.2))).to be(true)
      expect(loads).to eq([20.0, 20.0])
      expect(permits).to contain_exactly(include(epoch: 'replacement', sequence: 7))
    end
  end

  [0, 1].each do |over_ns|
    it "checks partial grant freshness after the final gate (deadline + #{over_ns}ns)" do
      observe(frame(6))
      trace = []
      elapsed = 0
      allow(controller).to receive(:monotonic_ns) do
        trace << :clock
        elapsed
      end
      allow(host_load).to receive(:median_with) do
        trace << :median
        elapsed = ns(5) + over_ns if trace.count(:median) == 2
        5
      end
      allow(workers).to receive(:dispatch) do |permit|
        trace << :dispatch
        permits << permit
        true
      end

      expect(observe(fixture)).to be(true)
      expect(trace).to eq(%i[clock median clock median clock] + (over_ns == 0 ? [:dispatch] : []))
      expect(loads).to eq([20.0])
      expect(score.stop_hits).to eq(2)
      if over_ns == 0
        expect(permits).to contain_exactly(include(action: :restart, id: '101', sequence: 7, run: [201, 12_345]))
        expect(controller.inflight.values).to eq(permits)
      else
        expect(permits).to be_empty
        expect(controller.inflight).to be_empty
        expect(score.restart_hits).to eq(2)
        expect(workers).not_to have_received(:publish).with(include(type: 'osctl_oomd'))
        expect(workers).not_to have_received(:publish).with(include(message: /guarded dispatch/))
        controller.tick(now_ns: ns(121))
        expect(permits).to be_empty
        expect(observe(frame(8, reason: 'missing_cgroup_value'))).to be(true)
        expect(permits).to contain_exactly(include(action: :restart, sequence: 8))
      end
    end
  end

  it 'rejects each overlong sweep and CPU envelope independently of completion freshness' do
    observe(frame(6))
    data = frame(7, reason: 'missing_cgroup_value')
    data['sample_completed_monotonic_ns'] = ns(120) + 1
    data['measurement_window_completed_monotonic_ns'] = ns(120) + 1
    expect(observe(data)).to be(false)
    expect(permits).to be_empty
    expect(score.stop_hits).to eq(1)
  end

  it 'retains a reservation through an unknown guarded result' do
    observe(frame(6))
    observe(fixture)
    permit = permits.fetch(0)
    allow(workers).to receive(:completions).and_yield(permit, :unknown)
    controller.tick(now_ns: ns(116))
    observe(frame(8, reason: 'missing_cgroup_value'))
    expect(permits).to eq([permit])
    expect(controller.status[:unknown_actions]).to eq(1)
    expect(score.stop_hits).to eq(2)
  end

  context 'with a pending restart in one of the two workers' do
    let(:load_top) { 1 }
    let(:stop_hits) { 3 }

    def competing_frame(sequence, stale:, replaced: false)
      data = frame(sequence, reason: stale ? 'invalid_run' : nil)
      first, peer = data['containers']
      first['loadavg'] = [50, 0, 0]
      peer.update('memory' => peer.fetch('memory_limit'), 'loadavg' => [40, 0, 0])
      peer['init_start_time_ticks'] += 1 if replaced
      if stale
        data['inventory_complete'] = false
        # osctld still counts both containers as running after the payload exits.
        %w[init_pid init_start_time_ticks cpu_usage cpu_baseline_sequence cpu_window_started_monotonic_ns
           memory memory_limit cpu_limit nproc loadavg].each { |key| first[key] = nil }
        first.update('run_verified' => false, 'memory_limit_state' => 'unknown', 'cpu_limit_state' => 'unknown',
                     'errors' => { 'run' => 'invalid_run' })
      end
      data
    end

    [false, true].each do |exited|
      it "runs a peer restart and stop before the first command completes (init exited: #{exited})" do
        commands = Queue.new
        finish_restart = Queue.new
        workers = OsCtl::Oomd::ActionWorkers.new(size: 2, dry_run: false, notifier: ->(_) {},
                                                 executor: lambda { |permit|
                                                   commands << permit
                                                   finish_restart.pop if permit[:id] == '101'
                                                   true
                                                 })
        actor = described_class.new(interval: 15, cpu_percent: 90, memory_percent: 95, load_multiplier: 2,
                                    load_top:, restart_hits:, stop_hits:, rtnl_watchdog: {}, workers:, host_load:)
        actor.start
        actor.child_started
        sample = lambda do |sequence, **opts|
          data = competing_frame(sequence, **opts)
          actor.observe(data, now_ns: data.fetch('sample_completed_monotonic_ns'))
        end

        Timeout.timeout(3) do
          [6, 7].each { |seq| sample.call(seq, stale: false) }
          first = commands.pop
          expect(first).to include(id: '101', action: :restart, sequence: 7)
          [8, 9].each { |seq| sample.call(seq, stale: exited) }
          expect(commands.pop).to include(id: '102', action: :restart, sequence: 9, run: [202, 23_456])
          while actor.inflight.has_key?(%w[tank 102])
            actor.tick(now_ns: ns(146))
            Thread.pass
          end

          # A new init with the same PID needs its own pair before granting the stop.
          sample.call(10, stale: exited, replaced: true)
          expect(actor.export.find { |r| r.id == '102' }.stop_hits).to eq(2)
          expect(commands).to be_empty
          sample.call(11, stale: exited, replaced: true)
          expect(commands.pop).to include(id: '102', action: :stop, sequence: 11, run: [202, 23_457])
          expect(actor.inflight.fetch(%w[tank 101])).to equal(first)
        end
      ensure
        finish_restart << true
        actor&.stop
      end
    end
  end

  it 'does not queue a restart if all physical slots are busy' do
    observe(frame(6))
    allow(workers).to receive(:dispatch).and_return(false)
    observe(fixture)
    expect(workers).to have_received(:dispatch).once
    controller.tick(now_ns: ns(116))
    expect(workers).to have_received(:dispatch).once
    expect(controller.inflight).to be_empty
  end

  context 'with an unknown peer outside the worst rank bound' do
    let(:load_top) { 3 }

    it 'rejects an unverified peer in a purportedly closed roster even when all ranks qualify' do
      observe(frame(6))
      raw = fixture
      peer = raw['containers'][1]
      %w[init_pid init_start_time_ticks cpu_usage cpu_baseline_sequence cpu_window_started_monotonic_ns
         cpu_limit memory_limit nproc loadavg].each { |key| peer[key] = nil }
      peer.update('run_verified' => false, 'cpu_limit_state' => 'unknown', 'memory_limit_state' => 'unknown',
                  'errors' => { 'run' => 'run_changed' })
      expect(observe(raw)).to be(false)
      expect(permits).to be_empty
      expect(loads).to eq([20.0])
      expect([score.restart_hits, score.stop_hits]).to eq([1, 1])
    end

    it 'scores the verified target when a peer has no path and keeps the strict history separate' do
      observe(frame(6))
      raw = fixture.merge('inventory_complete' => false, 'invalid_reason' => 'invalid_run')
      peer = raw['containers'][1]
      %w[group_path init_pid init_start_time_ticks cpu_usage cpu_baseline_sequence cpu_window_started_monotonic_ns
         cpu_limit memory_limit nproc loadavg].each { |key| peer[key] = nil }
      peer.update('run_verified' => false, 'cpu_limit_state' => 'unknown', 'memory_limit_state' => 'unknown',
                  'errors' => { 'run' => 'invalid_run' })
      index = OsCtl::Oomd::Eligibility::Partial
      expect(index.index(raw)).to include(%w[tank 102] => peer)
      expect(index.index(raw.merge('inventory_complete' => true))).to be_nil
      [peer.except('group_path'), peer.merge('run_verified' => true), peer.merge('tx' => {})].each do |invalid|
        expect(index.index(raw.merge('containers' => [raw['containers'].first, invalid, raw['containers'].last]))).to be_nil
      end
      expect(observe(raw)).to be(true)
      expect(permits).to contain_exactly(include(action: :restart, id: '101', sequence: 7))
      expect(controller.inflight.values).to eq(permits)
      expect(loads).to eq([20.0])
      expect([score.restart_hits, score.stop_hits]).to eq([0, 2])
      warmup = frame(8, reason: 'initial_baseline')
      warmup['containers'][1].update('cpu_usage' => nil, 'cpu_baseline_sequence' => nil,
                                     'cpu_window_started_monotonic_ns' => nil, 'errors' => { 'cpu_usage' => 'initial_baseline' })
      expect(observe(warmup)).to be(true)
      expect(loads).to eq([20.0])
      expect(observe(frame(9))).to be(true)
      expect(loads).to eq([20.0, 20.0])
      expect(permits.size).to eq(1)
    end

    it 'qualifies A even when B only lacks a load reading' do
      observe(frame(6))
      raw = frame(7, reason: 'missing_container_load')
      raw['containers'][1]['loadavg'] = nil
      raw['containers'][1]['errors']['loadavg'] = 'missing_container_load'
      observe(raw)
      expect(permits).to contain_exactly(include(action: :restart, id: '101', sequence: 7))
      expect(score.stop_hits).to eq(2)
    end
  end

  context 'when the next hit reaches both thresholds' do
    let(:stop_hits) { 2 }

    it 'grants the stop on the partial frame that earned it' do
      observe(frame(6))
      expect(score.stop_hits).to eq(1)
      observe(fixture)
      expect(score.stop_hits).to eq(2)
      expect(permits).to contain_exactly(include(action: :stop, sequence: 7))
    end
  end

  context 'when a stop is already due but its slot was unavailable' do
    let(:stop_hits) { 1 }

    it 'does not substitute a partial restart after the physical slot becomes free' do
      allow(workers).to receive(:dispatch).and_return(false)
      observe(frame(6))
      expect(score.stop_hits).to eq(1)
      allow(workers).to receive(:dispatch) do |permit|
        permits << permit
        true
      end
      observe(fixture)
      expect(score.stop_hits).to eq(2)
      expect(permits).to contain_exactly(include(action: :stop, sequence: 7))
    end
  end

  context 'when the watchdog reports distress' do
    let(:watchdog_enabled) { true }

    it 'expires one partial hit without scoring a heartbeat or filling a fresh grant' do
      allow(watchdog).to receive(:episode).and_return(['probe', 1])
      controller.tick(now_ns: ns(101))
      observe(frame(6), now: ns(102))
      observe(fixture)
      expect(score.restart_hits).to eq(1)
      controller.tick(now_ns: ns(136))
      expect(score.restart_hits).to eq(0)
      expect(score.stop_hits).to eq(2)
      expect(permits).to be_empty
    end

    [%w[global], %w[host], %w[global host]].each do |missing|
      it "rejects missing #{missing.join(' and ')} load keys, not just mismatched readings" do
        allow(watchdog).to receive(:episode).and_return(['probe', 1])
        controller.tick(now_ns: ns(99))
        observe(frame(6))
        raw = fixture
        raw['loadavg'] = raw['containers'].last['loadavg'] = nil
        raw.delete('loadavg') if missing.include?('global')
        raw['containers'].last.delete('loadavg') if missing.include?('host')
        expect(observe(raw)).to be(false)
        expect(score.restart_hits).to eq(0)
        expect(loads).to eq([20.0])
        expect(permits).to be_empty
      end
    end

    it 'can still prove rank with unknown host load without opening the stop gate' do
      allow(watchdog).to receive(:episode).and_return(['probe', 1])
      controller.tick(now_ns: ns(101))
      observe(frame(6), now: ns(102))
      [7, 8].each do |sequence|
        raw = frame(sequence, reason: 'missing_cgroup_value')
        raw['loadavg'] = raw['containers'].last['loadavg'] = nil
        observe(raw)
      end
      expect(permits).to contain_exactly(include(action: :restart, id: '101', sequence: 8))
      expect(score.stop_hits).to eq(1)
      expect(loads).to eq([20.0])
    end

    it 'needs two fresh distinct post-entry hits and a verified adjacent run' do
      allow(watchdog).to receive(:episode).and_return(['probe', 1])
      controller.tick(now_ns: ns(101))
      observe(frame(6), now: ns(102))
      expect(observe(fixture)).to be(true)
      expect(observe(fixture)).to be(false)
      expect(score.restart_hits).to eq(1)
      expect(permits).to be_empty
      expect(observe(frame(8, reason: 'missing_cgroup_value'))).to be(true)
      expect(permits).to contain_exactly(include(action: :restart, id: '101', sequence: 8, watchdog_episode: ['probe', 1]))
    end
  end
end
