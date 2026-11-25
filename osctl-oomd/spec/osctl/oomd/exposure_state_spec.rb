require 'spec_helper'

RSpec.describe OsCtl::Oomd::ExposureState do
  let(:boot) { '00000000-0000-4000-8000-000000000001' }
  let(:now) { 20_000_000_000 }
  let(:primary) do
    { boot_id: boot, epoch: 'observer-A', error_code: 0, observed_monotonic_ns: now,
      latency_run: { 'version' => 1, 'valid' => true, 'cutoff_ns' => 1_000_000_000,
                     'interval_ns' => 1_000_000_000, 'tick_ns' => 250_000_000 } }
  end
  let(:cache) do
    { 'schema' => 1, 'boot_id' => boot, 'epoch' => 'observer-A', 'observed_monotonic_ns' => now,
      'cutoff_ns' => 1_000_000_000, 'interval_ns' => 1_000_000_000, 'coverage_started_ns' => 1,
      'coverage_valid' => true, 'paused' => false, 'first_sequence' => 1, 'last_sequence' => 1,
      'records' => [[1, 1, 10_000_000_000, 13_000_000_000, 0, 1, true]], 'pending' => nil }
  end
  let(:reader) { described_class.new(path: '/synthetic', boot_id: boot) }

  def read(value = cache, watchdog: primary, at: now)
    allow(reader).to receive(:read_file).and_return(value)
    reader.read(now_ns: at, watchdog:)
  end

  it 'requires a fresh validated primary binding and matching boot, epoch, cadence and cutoff' do
    expect(read).to eq(cache)
    expect(reader.gap).to be(true)
    expect(read(cache.dup)).to eq(cache)
    expect(reader.gap).to be(false)
    expect(read(watchdog: nil)).to be_nil
    %w[boot_id epoch cutoff_ns interval_ns coverage_valid paused observed_monotonic_ns pending].each do |field|
      value = cache.dup
      value.delete(field)
      expect(read(value)).to be_nil
    end
    expect(read(cache.merge('observed_monotonic_ns' => now + 100_000_000))).to be_nil
    expect(read(at: now + 1_100_000_000)).to be_nil
    expect(read(cache.merge('paused' => true))).to be_nil
    expect(read(cache.merge('interval_ns' => 500_000_000))).to be_nil
  end

  it 'detects overwritten terminals, error terminals, mutation, epoch and coverage gaps without bridging' do
    read
    error = cache.merge('observed_monotonic_ns' => now + 1, 'last_sequence' => 2,
                        'records' => cache['records'] + [[2, 2, 14_000_000_000, 15_000_000_000, 5, 1, false]])
    expect(read(error, at: now + 1)).not_to be_nil
    expect(reader.gap).to be(true)
    overwritten = cache.merge('observed_monotonic_ns' => now + 2, 'first_sequence' => 4, 'last_sequence' => 4,
                              'records' => [[4, 4, 16_000_000_000, 17_000_000_000, 0, 1, true]])
    expect(read(overwritten, at: now + 2)).not_to be_nil
    expect(reader.gap).to be(true)
    mutation = Marshal.load(Marshal.dump(overwritten))
    mutation['observed_monotonic_ns'] += 1
    mutation['records'][0][3] += 1
    expect(read(mutation, at: now + 3)).to be_nil
    read
    expect(read(cache.merge('epoch' => 'observer-B'), watchdog: primary.merge(epoch: 'observer-B'))).not_to be_nil
    expect(reader.gap).to be(true)
  end

  it 'rejects malformed sequence, time and coverage claims including an unannounced pending probe' do
    [[0, 1, 10, 13, 0, 1, true], [1, 1, 14, 13, 0, 1, true], [1, 1, 10, 13, 8, 1, false],
     [1, 1, nil, 13, 0, 1, true], [1, 1, 10, 13, 5, 1, true]].each do |tuple|
      expect(read(cache.merge('records' => [tuple]))).to be_nil
    end
    pending = { 'probe' => 2, 'started_ns_or_null' => nil, 'coverage_started_ns_or_null' => 1, 'coverage_valid' => true }
    expect(read(cache.merge('pending' => pending))).to be_nil
    pending['coverage_valid'] = false
    expect(read(cache.merge('pending' => pending))).not_to be_nil
    expect(read(cache.merge('records' => cache['records'] * 129))).to be_nil
  end

  it 'uses bounded non-following reads and exact private root ownership' do
    file = instance_double(File)
    stat = instance_double(File::Stat, file?: true, uid: 0, mode: 0o100600)
    allow(File).to receive(:open).with('/synthetic', File::RDONLY | File::NOFOLLOW | File::NONBLOCK).and_yield(file)
    allow(file).to receive_messages(stat:, read: JSON.generate(cache))
    expect(reader.read(now_ns: now, watchdog: primary)).not_to be_nil
    expect(file).to have_received(:read).with(32_769)
    allow(stat).to receive(:mode).and_return(0o100644)
    expect(reader.read(now_ns: now, watchdog: primary)).to be_nil
    allow(stat).to receive(:mode).and_return(0o100600)
    allow(stat).to receive(:uid).and_return(1000)
    expect(reader.read(now_ns: now, watchdog: primary)).to be_nil
    allow(stat).to receive(:uid).and_return(0)
    allow(file).to receive_messages(stat:, read: 'x' * 32_769)
    expect(reader.read(now_ns: now, watchdog: primary)).to be_nil
  end
end
