# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Oomd::WatchdogState do
  let(:reader) { described_class.new(path: '/unused', max_age_seconds: 1, boot_id: 'boot') }
  let(:frame) do
    { 'schema' => 1, 'boot_id' => 'boot', 'epoch' => 'observer', 'sequence' => 1,
      'observed_monotonic_ns' => 2_000_000_000, 'probe_sequence' => 1, 'state' => 'distressed',
      'dispatch_monotonic_ns' => 500_000_000, 'started_monotonic_ns' => 600_000_000,
      'completed_monotonic_ns' => nil, 'last_duration_ns' => nil, 'expected_errno' => 22, 'error_code' => 0 }
  end

  before { allow(reader).to receive(:read_frame) { frame.dup } }

  def read(now = 2_000_000_000) = reader.episode(now_ns: now)

  def next_frame
    frame['sequence'] += 1
    frame['observed_monotonic_ns'] += 250_000_000
    read(frame['observed_monotonic_ns'])
  end

  it 'requires two ordered fresh frames per observer epoch including first-probe startup distress' do
    expect(read).to be_nil
    expect(next_frame).to eq(['observer', 1])
    expect(read(2_250_000_000)).to eq(['observer', 1])
    frame['epoch'] = 'replacement'
    expect(next_frame).to be_nil
    expect(next_frame).to eq(['replacement', 1])
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
    expect(next_frame).to eq(['observer', 1])
    frame['boot_id'] = 'other'
    expect(next_frame).to be_nil
    frame['boot_id'] = 'boot'
    expect(next_frame).to be_nil
    expect(next_frame).to eq(['observer', 1])
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
    expect(next_frame).to eq(['observer', 1])
  end

  it 'rejects symlinks, non-root ownership, writable-by-others files and oversized content' do
    with_tmpdir do |dir|
      path = File.join(dir, 'state')
      File.write(path, JSON.generate(frame))
      File.chmod(0o666, path)
      actual = described_class.new(path:, max_age_seconds: 1, boot_id: 'boot')
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
