# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe OsCtl::Oomd::Controller do
  let(:watchdog) { instance_double(OsCtl::Oomd::WatchdogState, episode: nil, diagnostic: nil, details: nil) }
  let(:workers) do
    instance_double(OsCtl::Oomd::ActionWorkers, start: nil, stop: nil, publish: true,
                                                completions: nil, notification_drops: 0, notification_failures: 0)
  end
  let(:host_load) { instance_double(OsCtl::Oomd::HostLoad, median: 100, median_with: 100, established?: true) }
  let(:permits) { [] }
  let(:controller) do
    described_class.new(interval:, cpu_percent: 90, memory_percent: 95, load_multiplier: 2,
                        load_top: 2, restart_after_seconds: 90, stop_after_seconds: 600, rtnl_watchdog: { 'enable' => true },
                        watchdog:, workers:, host_load:)
  end

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
    controller.observe(frame(sequence, time, rows, **changes), now_ns: ns(time))
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
      actual_workers = OsCtl::Oomd::ActionWorkers.new(size: 1, dry_run: true,
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
      expect(notices).to all(include(type: :log))
      expect(notices).to include(include(message: /would #{action} tank:a.*result=simulated/))
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
        expect(workers).not_to have_received(:publish).with(include(type: 'osctl_oomd'))
        expect(workers).not_to have_received(:publish).with(include(message: /guarded dispatch/))
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
