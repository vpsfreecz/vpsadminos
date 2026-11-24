# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Oomd::WatchdogState do
  let(:reader) { described_class.new(path: '/unused', max_age_seconds: 1, pending_seconds: 1, boot_id: 'boot') }
  let(:frame) do
    { 'schema' => 1, 'boot_id' => 'boot', 'epoch' => 'observer', 'sequence' => 1,
      'observed_monotonic_ns' => 2_000_000_000, 'probe_sequence' => 1, 'state' => 'distressed',
      'dispatch_monotonic_ns' => 500_000_000, 'started_monotonic_ns' => 600_000_000,
      'completed_monotonic_ns' => nil, 'last_duration_ns' => nil, 'expected_errno' => 22, 'error_code' => 0,
      'latency_run' => { 'version' => 1, 'cutoff_ns' => 1_000_000_000, 'interval_ns' => 1_000_000_000,
                         'tick_ns' => 250_000_000, 'coverage_started_ns' => 1,
                         'valid' => true, 'slow_count' => 0, 'first_probe' => nil, 'last_probe' => nil,
                         'first_started_ns' => nil, 'last_completed_ns' => nil } }
  end

  before { allow(reader).to receive(:read_frame) { frame.dup } }

  def read(now = 2_000_000_000) = reader.episode(now_ns: now)

  def next_frame
    frame['sequence'] += 1
    frame['observed_monotonic_ns'] += 250_000_000
    read(frame['observed_monotonic_ns'])
  end

  [nil, { 'version' => 2, 'state' => 'ready' }, { 'version' => 1, 'state' => 'invalid' }].each do |marker|
    it "keeps old control compatibility with unverified ordered evidence marker #{marker.inspect}" do
      frame['log_evidence'] = marker if marker
      read
      expect(next_frame).to be_a(Array)
      expect(reader.observation).to include(ordered_log_support: 'unverified_or_unsupported', cross_stream_complete: false)
    end
  end

  %w[ready backpressured draining].each do |state|
    it "reports producer capability state #{state} without treating it as delivery receipt" do
      frame['log_evidence'] = { 'version' => 1, 'state' => state }
      read
      expect(reader.observation).to include(ordered_log_support: 'supported', ordered_log_state: state, cross_stream_complete: false)
    end
  end

  it 'requires two ordered fresh frames per observer epoch including first-probe startup distress' do
    expect(read).to be_nil
    expect(next_frame).to be_a(Array)
    expect(read(2_250_000_000)).to be_a(Array)
    frame['epoch'] = 'replacement'
    expect(next_frame).to be_nil
    expect(next_frame).to be_a(Array)
  end

  it 'removes override immediately on healthy completion, preserving valid same-epoch binding' do
    read
    next_frame
    frame.merge!('state' => 'healthy', 'completed_monotonic_ns' => 2_300_000_000, 'last_duration_ns' => 1_700_000_000)
    expect(next_frame).to be_nil
  end

  it 'requires two new fresh frames after stale, future, malformed, error and wrong-boot data' do
    read
    next_frame
    expect(read(4_000_000_000)).to be_nil
    expect(next_frame).to be_nil
    expect(next_frame).to be_a(Array)
    frame['boot_id'] = 'other'
    expect(next_frame).to be_nil
    frame['boot_id'] = 'boot'
    expect(next_frame).to be_nil
    expect(next_frame).to be_a(Array)
    frame['observed_monotonic_ns'] = 9_000_000_000
    expect(read).to be_nil
  end

  it 'rejects regressed/duplicate-altered sequences and impossible pending/start/completion records' do
    read
    next_frame
    frame['sequence'] = 1
    expect(read(2_250_000_000)).to be_nil
    frame['started_monotonic_ns'] = nil
    expect(next_frame).to be_nil
    frame['started_monotonic_ns'] = 600_000_000
    frame['completed_monotonic_ns'] = 700_000_000
    expect(next_frame).to be_nil
  end

  it 'keeps both RTNL branches closed for old or mismatched summaries' do
    [nil, { 'version' => 2 }, frame['latency_run'].merge('cutoff_ns' => 2_000_000_000),
     frame['latency_run'].merge('interval_ns' => 2_000_000_000)].each do |summary|
      frame['latency_run'] = summary
      expect(next_frame).to be_nil
      expect(reader.diagnostic).not_to be_nil
    end
  end

  it 'does not activate pending at29.999 and activates only at30 continuously covered seconds' do
    actual = described_class.new(path: '/unused', max_age_seconds: 1, boot_id: 'boot')
    allow(actual).to receive(:read_frame) { frame.dup }
    frame['observed_monotonic_ns'] = 30_599_000_000
    frame['latency_run']['coverage_started_ns'] = 600_000_000
    expect(actual.episode(now_ns: 30_599_000_000)).to be_nil
    frame['sequence'] += 1
    frame['observed_monotonic_ns'] = 30_600_000_000
    expect(actual.episode(now_ns: 30_600_000_000)).to be_a(Array)
    expect(actual.episode(now_ns: 32_000_000_000)).to be_nil
  end

  it 'requires a completed30s span, clears at hidden-fast first-probe replacement and rebinds on gaps' do
    frame.merge!('probe_sequence' => 10, 'state' => 'healthy', 'dispatch_monotonic_ns' => 29_000_000_001,
                 'started_monotonic_ns' => 29_000_000_001, 'completed_monotonic_ns' => 30_000_000_001,
                 'last_duration_ns' => 1_000_000_000, 'observed_monotonic_ns' => 30_000_000_001)
    frame['latency_run'].merge!('slow_count' => 10, 'first_probe' => 1, 'last_probe' => 10,
                                'first_started_ns' => 1, 'last_completed_ns' => 30_000_000_000)
    expect(read(30_000_000_001)).to be_nil
    frame['sequence'] += 1
    frame['observed_monotonic_ns'] += 1
    expect(read(frame['observed_monotonic_ns'])).to be_nil # 29.999999999s
    frame['latency_run']['last_completed_ns'] += 1
    frame['sequence'] += 1
    frame['observed_monotonic_ns'] += 1
    first = read(frame['observed_monotonic_ns'])
    expect(first).to be_a(Array)
    frame['latency_run'].merge!('first_probe' => 8, 'slow_count' => 3, 'first_started_ns' => 25_000_000_000)
    frame['sequence'] += 1
    frame['observed_monotonic_ns'] += 1
    expect(read(frame['observed_monotonic_ns'])).to be_nil
  end

  it 'rejects oversized and malformed root-owned regular state at the actual bounded reader' do
    stat = instance_double(File::Stat, file?: true, uid: 0, mode: 0o600)
    io = instance_double(File, stat:, read: 'x' * 4097)
    allow(File).to receive(:open).with('/unused', File::RDONLY | File::NOFOLLOW | File::NONBLOCK).and_yield(io)
    allow(reader).to receive(:read_frame).and_call_original
    expect(read).to be_nil
    expect(io).to have_received(:read).with(4097)
    allow(io).to receive(:read).and_return('{bad')
    expect(read).to be_nil
    allow(io).to receive(:read) { JSON.generate(frame) }
    expect(read).to be_nil
    expect(next_frame).to be_a(Array)
  end

  it 'rejects symlinks, non-root ownership, writable-by-others files and oversized content' do
    with_tmpdir do |dir|
      path = File.join(dir, 'state')
      File.write(path, JSON.generate(frame))
      File.chmod(0o666, path)
      actual = described_class.new(path:, max_age_seconds: 1, pending_seconds: 1, boot_id: 'boot')
      expect(actual.episode(now_ns: 2_000_000_000)).to be_nil
      File.symlink(path, File.join(dir, 'link'))
      linked = described_class.new(path: File.join(dir, 'link'), max_age_seconds: 1, boot_id: 'boot')
      expect(linked.episode(now_ns: 2_000_000_000)).to be_nil
      File.write(path, 'x' * 4097)
      File.chmod(0o600, path)
      expect(actual.episode(now_ns: 2_000_000_000)).to be_nil
    end
  end
end
