# frozen_string_literal: true

require 'spec_helper'
require 'digest'

RSpec.describe OsCtl::Oomd::RtnlExposure do
  def ns(value) = value * 1_000_000_000
  def fixture = JSON.parse(File.read(File.join(__dir__, '../../fixtures/rtnl_exposure_v1.json')))
  def key = %w[tank 12345]

  def row
    { 'pool' => 'tank', 'id' => '12345', 'run_verified' => true, 'group_path' => '/osctl/pool.tank/ct.12345',
      'init_pid' => 2000, 'init_start_time_ticks' => 90_000, 'cpu_usage' => 96.0, 'cpu_limit' => 100,
      'memory' => 97, 'memory_limit' => 100, 'cpu_limit_state' => 'limited', 'memory_limit_state' => 'limited' }
  end

  let(:state) do
    { time: 10, accepted: true,
      cache: { 'epoch' => 'observer-A', 'observed_monotonic_ns' => ns(10), 'coverage_started_ns' => ns(9), 'records' => [], 'pending' => nil } }
  end
  let(:events) { [] }
  let(:reader) { instance_double(OsCtl::Oomd::ExposureState, gap: false) }
  let(:publisher) { instance_double(OsCtl::Oomd::ExposureEvents, start: nil, stop: nil, status: {}) }
  let(:actor) do
    described_class.new(interval: 5, cpu_percent: 90, memory_percent: 95, load_top: 5,
                        settings: { 'enable' => true }, reader:, publisher:,
                        boot_id: fixture['opts']['boot_id'],
                        clock: -> { [ns(state[:time]), 1_795_607_990_000_000 + (state[:time] * 1_000_000)] })
  end

  before do
    allow(reader).to receive(:read) { state[:cache] }
    allow(publisher).to receive(:publish) do |values|
      events.concat(values) if state[:accepted]
      state[:accepted]
    end
  end

  def sample(sequence, time, hit: true, rows: nil, linked: true)
    state[:time] = time
    state[:cache]['observed_monotonic_ns'] = ns(time) if state[:cache]
    actor.tick(now_ns: ns(time), watchdog: {})
    data = { 'epoch' => 'top-A', 'sequence' => sequence, 'sample_completed_monotonic_ns' => ns(time),
             'previous_sample_started_monotonic_ns' => ns(time - 5), 'inventory_complete' => false }
    rows ||= { key => row }
    rows = rows.transform_values { |ct| ct.merge('cpu_baseline_sequence' => sequence - 1, 'cpu_window_started_monotonic_ns' => ns(time - 5)) }
    actor.observe(data, rows:, qualifications: rows.to_h { |k, _| [k, hit] }, ranks: rows.to_h { |k, _| [k, 1] }, linked:)
  end

  def terminal(started = 10, completed = 13, probe = 77)
    [probe - 76, probe, ns(started), ns(completed), 0, ns(9), true]
  end

  def segments = events.flat_map { |event| event[:opts][:segments] }
  def credit = segments.sum { |segment| segment[:credit_us] }

  it 'matches the canonical fixture and counts exactly two seconds without either host gate' do
    path = File.join(__dir__, '../../fixtures/rtnl_exposure_v1.json')
    expect(Digest::SHA256.file(path).hexdigest).to eq('359f34cae1a6420503155d7cdf4a84f3f7928c8d4691eb9e3b5b9f3231332dea')
    sample(89, 10)
    state[:cache]['records'] = [terminal]
    sample(90, 15)
    result = JSON.parse(JSON.generate(events.last))
    expect(result['type']).to eq(fixture['type'])
    expect(result['opts'].slice('targets', 'segments', 'observed_at_us', 'observed_mono_us', 'policy')).to eq(fixture['opts'].slice('targets', 'segments', 'observed_at_us', 'observed_mono_us', 'policy'))
    expect(credit).to eq(2_000_000)
  end

  it 'credits pending and subsequent completion overlap once and excludes a strict one-second response' do
    sample(1, 10)
    state[:cache]['pending'] = { 'probe' => 77, 'started_ns_or_null' => ns(10), 'coverage_started_ns_or_null' => ns(9), 'coverage_valid' => true }
    sample(2, 12)
    expect(credit).to eq(1_000_000)
    expect(segments.last[:peak_is_lower_bound]).to be(true)
    state[:cache]['pending'] = nil
    state[:cache]['records'] = [terminal]
    sample(3, 15)
    expect(credit).to eq(2_000_000)
    state[:cache]['records'] << terminal(16, 17, 78)
    sample(4, 20)
    expect(credit).to eq(2_000_000)
  end

  it 'requires two qualified same-run observations and clips missed scheduling time to interval' do
    sample(1, 10, hit: false)
    state[:cache]['records'] = [terminal(10, 19)]
    sample(2, 15)
    expect(credit).to eq(0)
    sample(3, 25)
    expect(credit).to eq(0) # CPU window starts20; no backfill of the10..19 probe.
    state[:cache]['records'] = [terminal(26, 35, 78)]
    sample(4, 30, rows: { key => row.merge('init_start_time_ticks' => 90_001) })
    expect(credit).to eq(0)
  end

  it 'sends original-time zero-credit freshness, changed negative proof and vanished proof without idle flooding' do
    sample(1, 10)
    sample(2, 15)
    expect(events.size).to eq(1)
    sample(3, 20)
    sample(4, 25)
    expect(events.last[:opts]).to include(kind: 'heartbeat', observed_mono_us: 25_000_000, segments: [])
    sample(5, 30, hit: nil, rows: { key => row.merge('cpu_usage' => nil) })
    expect(events.last[:opts][:targets].first).to include(qualification: 'unknown', reason: 'resource_unknown')
    sample(6, 35)
    sample(7, 40, rows: {})
    expect(events.last[:opts][:targets].first).to include(qualification: 'unknown', run: nil, reason: 'vanished')
    emitted = events.size
    sample(8, 45, rows: Array.new(400) { |i| [['tank', i.to_s], row.merge('id' => i.to_s)] }.to_h, hit: false)
    expect(events.size).to eq(emitted)
  end

  it 'breaks credit on cache gaps, unavailable input and publisher pressure while retaining acute independence' do
    sample(1, 10)
    state[:cache]['records'] = [terminal(10, 40)]
    allow(reader).to receive(:gap).and_return(true)
    sample(2, 15)
    expect(credit).to eq(0)
    allow(reader).to receive(:gap).and_return(false)
    state[:accepted] = false
    sample(3, 20)
    expect(actor.status[:rtnl_exposure_paused]).to eq(1)
    state[:accepted] = true
    sample(4, 25)
    expect(credit).to eq(0)
    expect(events.last[:opts]).to include(gap_since_previous: true, gap_reason: 'pressure')
    sample(5, 30)
    expect(credit).to eq(5_000_000)
    state[:cache] = nil
    sample(6, 35)
    expect(events.last[:opts]).to include(coverage_valid: false, gap_since_previous: true)
  end

  it 'splits actual encoded data within every bound and marks oversized identities incomplete without truncation' do
    rows = Array.new(40) do |i|
      id = "#{i}#{'ž' * 120}"
      [['tank', id], row.merge('id' => id, 'group_path' => "/#{'x' * 1000}")]
    end.to_h
    sample(1, 10, rows:)
    expect(events.size).to be > 2
    expect(events.map { |event| event[:opts][:part] }).to eq((1..events.size).to_a)
    events.each do |event|
      expect(JSON.generate(event[:opts]).bytesize).to be <= 16_384
      expect(event[:opts][:targets].size).to be <= 16
      expect(event[:opts][:segments].size).to be <= 16
    end
    sample(2, 15, rows: { key => row.merge('id' => 'a' * 256) })
    expect(events.last[:opts]).to include(targets_complete: false, gap_reason: 'oversize', targets: [], segments: [])
  end

  it 'partitions selected proof and segment counts and resumes conservatively after selection overflow' do
    rows = Array.new(40) { |i| [['tank', i.to_s], row.merge('id' => i.to_s)] }.to_h
    sample(1, 10, rows:)
    state[:cache]['records'] = [terminal(10, 12), terminal(12, 15, 78)]
    sample(2, 15, rows:)
    batch = events.select { |event| event[:opts][:sample_sequence] == 2 }
    expect(batch.sum { |event| event[:opts][:segments].size }).to eq(80)
    expect(batch.size).to eq(5)
    expect(batch.all? { |event| event[:opts][:segments].size <= 16 && event[:opts][:targets].size <= 16 }).to be(true)
    expect(credit).to eq(40 * 3_000_000)
    rows = Array.new(1025) { |i| [['tank', i.to_s], row.merge('id' => i.to_s)] }.to_h
    sample(3, 20, rows:)
    expect(events.last[:opts]).to include(targets_complete: false, gap_reason: 'oversize', targets: [], segments: [])
    sample(4, 25)
    expect(events.last[:opts]).to include(gap_reason: 'oversize', segments: [])
  end

  it 'preserves authoritative decisive rank bounds as nullable context and never treats rank uncertainty as credit' do
    state[:time] = 10
    actor.tick(now_ns: ns(10), watchdog: {})
    data = { 'epoch' => 'top-A', 'sequence' => 1, 'sample_completed_monotonic_ns' => ns(10),
             'previous_sample_started_monotonic_ns' => ns(5), 'inventory_complete' => false }
    actor.observe(data, rows: { key => row }, qualifications: { key => true }, ranks: {}, linked: false)
    expect(events.last[:opts][:targets].first).to include(qualification: 'qualified', rank: nil)
    sample(2, 15, hit: nil)
    expect(events.last[:opts][:targets].first).to include(qualification: 'unknown', reason: 'rank_unknown', linked: false,
                                                          window_from_mono_us: nil, window_to_mono_us: nil)
    expect(credit).to eq(0)
  end

  it 'changes the producer epoch and seeds after a wall-clock discontinuity over one second' do
    sample(1, 10)
    old = events.last[:opts][:producer_epoch]
    allow(actor.instance_variable_get(:@clock)).to receive(:call).and_return([ns(15), 1_795_608_008_000_000])
    state[:cache]['records'] = [terminal]
    sample(2, 15)
    expect(events.last[:opts]).to include(gap_reason: 'clock_change', segments: [])
    expect(events.last[:opts][:producer_epoch]).not_to eq(old)
  end
end
