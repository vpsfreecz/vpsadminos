# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe OsCtl::Oomd::Controller do
  let(:watchdog) { instance_double(OsCtl::Oomd::WatchdogState, episode: nil) }
  let(:workers) do
    instance_double(OsCtl::Oomd::ActionWorkers, start: nil, stop: nil, publish: true,
                                                completions: nil, notification_drops: 0, notification_failures: 0)
  end
  let(:host_load) { instance_double(OsCtl::Oomd::HostLoad, median: 100, median_with: 100) }
  let(:permits) { [] }
  let(:controller) do
    described_class.new(interval:, cpu_percent: 90, memory_percent: 95, load_multiplier: 2,
                        load_top: 2, restart_hits: 8, stop_hits: 40, rtnl_watchdog: { 'enable' => true },
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

  it 'keeps production defaults off at fifteen seconds and ordinary eight/forty hits' do
    options = OsCtl::Oomd::Cli.new.send(:parse, [])
    expect(options).to include('interval' => 15, 'restart_hits' => 8, 'stop_hits' => 40)
    expect(options.fetch('rtnl_watchdog')).to include('enable' => false, 'state_file' => '/run/rtnl-watchdog.json', 'restart_hits' => 2, 'action_workers' => 2)
    expect { described_class.settings('restart_hits' => 1) }.to raise_error(ArgumentError)
    expect { described_class.settings('action_workers' => 3) }.to raise_error(ArgumentError)
  end

  it 'requires the generic schema without accepting the replaced oomd schema' do
    expect(controller.observe(frame(1, 100, top_schema: nil, oomd_schema: 1), now_ns: ns(100))).to be(false)
    expect(controller.observe(frame(1, 100), now_ns: ns(100))).to be(false)
    expect(controller.observe(frame(2, 115), now_ns: ns(115))).to be(true)
    expect(permits).to be_empty
  end

  it 'requires all three typed effective collectors to be disabled' do
    invalid = [nil, {}, { 'netif' => false, 'zfs' => false }]
    %w[netif zfs iostat].each do |key|
      [true, nil, 0, 'false'].each do |value|
        invalid << { 'netif' => false, 'zfs' => false, 'iostat' => false }.merge(key => value)
      end
    end
    invalid.each do |collectors|
      expect(controller.observe(frame(1, 100, collectors:), now_ns: ns(100))).to be(false)
    end
    expect(controller.observe(frame(1, 100), now_ns: ns(100))).to be(false)
    expect(controller.observe(frame(2, 115), now_ns: ns(115))).to be(true)
    expect(permits).to be_empty
  end

  it 'accepts independent five-second sweep and age budgets and a twenty-second CPU envelope' do
    data = frame(1, 100, sample_started_monotonic_ns: ns(95),
                         measurement_window_started_monotonic_ns: ns(80))
    expect(controller.observe(data, now_ns: ns(105))).to be(true)
    expect(permits).to be_empty
  end

  it 'rejects overlong sweeps, aged completions and stretched or incoherent CPU envelopes' do
    invalid = [
      { sample_started_monotonic_ns: ns(95) - 1 },
      { measurement_window_started_monotonic_ns: ns(80) - 1 },
      { measurement_window_started_monotonic_ns: ns(99.9) },
      { measurement_window_started_monotonic_ns: nil },
      { measurement_window_completed_monotonic_ns: ns(100) - 1 }
    ]
    invalid.each do |changes|
      expect(controller.observe(frame(1, 100, **changes), now_ns: ns(100))).to be(false)
    end
    expect(controller.observe(frame(1, 100), now_ns: ns(105) + 1)).to be(false)
    expect(permits).to be_empty
  end

  context 'with the disposable one-second interval' do
    def interval = 1

    it 'accepts a six-second CPU envelope and rejects one nanosecond longer' do
      expect(observe(1, 100, measurement_window_started_monotonic_ns: ns(94) - 1)).to be(false)
      expect(observe(1, 100, measurement_window_started_monotonic_ns: ns(94))).to be(false)
      expect(observe(2, 101)).to be(true)
    end
  end

  it 'requires baseline linkage for consecutive complete frames and recovers after invalidity' do
    enter_episode(99)
    expect(observe(1, 100)).to be(true)
    expect(score.restart_hits).to eq(1)
    expect(observe(2, 115, measurement_window_started_monotonic_ns: ns(99))).to be(false)
    expect(score.restart_hits).to eq(0)
    expect(permits).to be_empty
    expect(observe(3, 130)).to be(false)
    expect(score.restart_hits).to eq(0)
    expect(observe(4, 145)).to be(true)
    expect(score.restart_hits).to eq(1)
    expect(observe(5, 160)).to be(true)
    expect(permits.size).to eq(1)
  end

  it 'retains ordinary seven-hit evidence through a stretched CPU window without dispatching it' do
    7.times { |i| observe(i + 1, 1 + (15 * i), loadavg: [300]) }
    expect(observe(8, 106, measurement_window_started_monotonic_ns: ns(80), loadavg: [300])).to be(false)
    expect(score.restart_hits).to eq(7)
    expect(score.stop_hits).to eq(7)
    expect(permits).to be_empty
    expect(observe(9, 121, loadavg: [300])).to be(false)
    expect(observe(10, 136, loadavg: [300])).to be(true)
    expect(permits.size).to eq(1)
  end

  it 'needs two distinct raw post-entry observations and never scores heartbeats or duplicates' do
    enter_episode
    observe(1, 2)
    10.times { controller.tick(now_ns: ns(2.5)) }
    observe(1, 2)
    expect(score.restart_hits).to eq(1)
    expect(permits).to be_empty
    observe(2, 17)
    expect(permits.size).to eq(1)
    expect(permits.first).to include(action: :restart, run: [42, 123], sequence: 3)
    expect(score.stop_hits).to eq(0)
    expect(score.restart_hits).to eq(0)
  end

  it 'rejects an observation whose sweep began before episode entry' do
    enter_episode(2)
    observe(1, 2)
    observe(2, 17)
    expect(score.restart_hits).to eq(1)
    expect(permits).to be_empty
  end

  it 'decrements raw misses, floors zero, and preserves the original memory/CPU/rank gates' do
    enter_episode
    observe(1, 2)
    observe(2, 17, [row(memory: 80)])
    observe(3, 32, [row(cpu_usage: 80)])
    observe(4, 47, [row(memory_limit: nil)])
    expect(score.restart_hits).to eq(0)
    expect(score.stop_hits).to eq(0)
    expect(permits).to be_empty
  end

  it 'keeps the synthetic host row in top-N ranking' do
    enter_episode
    observe(1, 2, [row('b', loadavg: [90]), row], loadavg: [100])
    observe(2, 17, [row('b', loadavg: [90]), row], loadavg: [100])
    expect(permits.map { |permit| permit[:id] }).to eq(['b'])
    expect(score.restart_hits).to eq(0)
  end

  it 'never changes stop history during watchdog-only observations, even misses or invalidity' do
    observe(1, 1, [row], loadavg: [300])
    expect(score.stop_hits).to eq(1)
    enter_episode(2)
    observe(2, 3, [row(memory: 20)], measurement_window_started_monotonic_ns: ns(0.9))
    observe(3, 18, [row], complete: false)
    expect(score.stop_hits).to eq(1)
    allow(watchdog).to receive(:episode).and_return(nil)
    expect(observe(4, 33, [row(memory: 20)], loadavg: [300])).to be(false)
    observe(5, 48, [row(memory: 20)], loadavg: [300])
    expect(score.stop_hits).to eq(0)
  end

  [false, true].product(%i[restart stop]).each do |enabled, action|
    it "simulates #{action} without executor or real event (watchdog enabled: #{enabled})" do
      executed = Queue.new
      events = Queue.new
      actual_workers = OsCtl::Oomd::ActionWorkers.new(size: 1, dry_run: true,
                                                      executor: lambda { |permit|
                                                        executed << permit
                                                        true
                                                      },
                                                      notifier: ->(event) { events << event })
      actor = described_class.new(interval:, cpu_percent: 90, memory_percent: 95, load_multiplier: 2,
                                  load_top: 2, restart_hits: 2, stop_hits: action == :stop ? 2 : 40,
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
      expect(actor.export.first.restart_hits).to eq(0)
      preserved = action == :restart && !enabled ? 2 : 0
      expect(actor.export.first.stop_hits).to eq(preserved)
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

  it 'suppresses zero-score miss logs without changing exported scores' do
    observe(1, 100, [row(memory: 50)], loadavg: [300])
    expect([score.restart_hits, score.stop_hits]).to eq([0, 0])
    expect(workers).not_to have_received(:publish)
    observe(2, 115, [row], loadavg: [300])
    observe(3, 130, [row(memory: 50)], loadavg: [300])
    expect(workers).to have_received(:publish).with(include(message: /tank:a miss/)).once
    observe(4, 145, [row(memory: 50)], loadavg: [300])
    expect(workers).to have_received(:publish).with(include(message: /tank:a miss/)).once
  end

  it 'uses ordinary eight-hit restart behavior when load alone activates the policy' do
    8.times { |i| observe(i + 1, 1 + (15 * i), [row], loadavg: [300]) }
    expect(permits.size).to eq(1)
    expect(score.stop_hits).to eq(8)
  end

  it 'preserves ordinary same-run seven hits through invalidity, missing frames and sampler replacement' do
    7.times { |i| observe(i + 1, 1 + (15 * i), [row], loadavg: [300]) }
    expect(score.restart_hits).to eq(7)
    observe(8, 106, complete: false)
    controller.tick(now_ns: ns(150))
    expect(score.restart_hits).to eq(7)
    expect(permits).to be_empty
    controller.child_started
    observe(1, 151, [row], epoch: 'replacement', loadavg: [300])
    expect(permits.size).to eq(1)
  end

  it 'rejects a header-only transition and a retired epoch even after a child boundary' do
    enter_episode
    observe(1, 2)
    expect(observe(1, 3, epoch: 'replacement')).to be(false)
    expect(score.restart_hits).to eq(0)
    controller.child_started
    expect(observe(1, 4, epoch: 'replacement')).to be(true)
    expect(score.restart_hits).to eq(1)
    controller.child_started
    expect(observe(2, 17)).to be(false)
    expect(score.restart_hits).to eq(0)
    expect(permits).to be_empty
  end

  it 'keeps original stop priority and forty-hit history across successful restarts' do
    40.times do |i|
      observe(i + 1, 1 + (15 * i), [row], loadavg: [300])
      next if permits.empty?

      permit = permits.last
      allow(workers).to receive(:completions) do |&block|
        block.call(permit, :success) if controller.inflight.has_key?(%w[tank a])
      end
    end
    expect(permits.last[:action]).to eq(:stop)
    controller.tick(now_ns: ns(587))
    expect(score.stop_hits).to eq(0)
  end

  it 'clears evidence at invalidity, sequence gaps, sampler epoch changes and missed sample deadlines' do
    enter_episode
    observe(1, 2)
    observe(2, 17, complete: false)
    expect(score.restart_hits).to eq(0)
    expect(seed(3, 32)).to be(false)
    expect(observe(4, 47)).to be(true)
    expect(score.restart_hits).to eq(1)
    expect(observe(6, 62)).to be(false)
    expect(score.restart_hits).to eq(0)
    controller.child_started
    observe(1, 77, epoch: 'replacement')
    expect(score.restart_hits).to eq(1)
    controller.tick(now_ns: ns(97.1))
    expect(score.restart_hits).to eq(0)
    expect(permits).to be_empty
  end

  it 'cannot extend evidence lifetime with duplicate frames or heartbeats' do
    enter_episode
    observe(1, 2)
    observe(1, 5)
    controller.tick(now_ns: ns(22.1))
    expect(score.restart_hits).to eq(0)
    expect(permits).to be_empty
  end

  it 'clears accelerated evidence when healthy, stale, error or a new watchdog episode removes the override' do
    enter_episode
    observe(1, 2)
    allow(watchdog).to receive(:episode).and_return(nil)
    controller.tick(now_ns: ns(3))
    expect(controller.restart_hits).to eq(8)
    expect(score.restart_hits).to eq(0)
    enter_episode(4, ['new', 1])
    observe(2, 17)
    expect(score.restart_hits).to eq(1)
    expect(permits).to be_empty
  end

  it 'rechecks watchdog freshness and the effective threshold at the physical slot grant' do
    enter_episode
    observe(1, 2)
    allow(watchdog).to receive(:episode).and_return(['watchdog', 1], nil)
    observe(2, 17)
    expect(controller.restart_hits).to eq(8)
    expect(score.restart_hits).to eq(0)
    expect(permits).to be_empty
  end

  it 'rechecks dispatch age after controller processing and rejects replayed acquisition times' do
    enter_episode
    observe(1, 2)
    allow(controller).to receive(:monotonic_ns).and_return(0, ns(6))
    observe(2, 17)
    expect(score.restart_hits).to eq(2)
    expect(permits).to be_empty
    observe(3, 17)
    expect(score.restart_hits).to eq(0)
    expect(permits).to be_empty
  end

  it 'does not dispatch from old, overlong, missing-schema or run-invalid input' do
    enter_episode
    samples = [frame(1, 2).merge('top_schema' => nil),
               frame(2, 3).merge('sample_started_monotonic_ns' => ns(0.1)),
               frame(3, 4, [row(init_pid: nil)]), frame(4, 5)]
    samples.each { |data| controller.observe(data, now_ns: ns(20)) }
    expect(permits).to be_empty
  end

  it 'does not reuse old-run hits for a replacement init' do
    enter_episode
    observe(1, 2)
    seed(2, 17, [row(init_start_time_ticks: 124)])
    observe(3, 32, [row(init_start_time_ticks: 124)])
    expect(score.restart_hits).to eq(1)
    expect(permits).to be_empty
  end

  it 'deduplicates in-flight VPSes and requires new observations after actual completion' do
    enter_episode
    observe(1, 2)
    observe(2, 17)
    observe(3, 32)
    expect(permits.size).to eq(1)
    permit = permits.first
    allow(workers).to receive(:completions).and_yield(permit, :failed)
    controller.tick(now_ns: ns(33))
    expect(permits.size).to eq(1)
    expect(controller.inflight).to be_empty
    observe(4, 47)
    expect(score.restart_hits).to eq(1)
  end

  it 'retains uncertain actions and their VPS reservations' do
    enter_episode
    observe(1, 2)
    observe(2, 17)
    allow(workers).to receive(:completions).and_yield(permits.first, :unknown)
    controller.tick(now_ns: ns(18))
    observe(3, 32)
    expect(controller.status[:unknown_actions]).to eq(1)
    expect(permits.size).to eq(1)
  end

  it 'does not retry a stale permit when a busy slot becomes free' do
    enter_episode
    allow(workers).to receive(:dispatch).and_return(false)
    observe(1, 2)
    observe(2, 17)
    expect(controller.inflight).to be_empty
    allow(workers).to receive(:dispatch) { |permit|
      permits << permit
      true
    }
    controller.tick(now_ns: ns(18))
    expect(permits).to be_empty
    observe(3, 32, [row(memory: 20)])
    expect(permits).to be_empty
  end
end
