# frozen_string_literal: true

# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/InstanceVariable

require 'osctld/container_state_history'

RSpec.describe OsCtld::ContainerStateHistory do
  let(:boot_id) { '00000000-0000-4000-8000-000000000001' }
  let(:other_boot_id) { '00000000-0000-4000-8000-000000000002' }
  let(:path) { File.join(@dir, 'container-state-history.json') }
  let(:boot_id_path) { File.join(@dir, 'boot-id') }
  let(:support_path) { File.join(@dir, 'support') }
  let(:history) { described_class.new(path:, boot_id_path:, support_path:) }
  let(:empty_state) { { schema_version: 1, boot_id:, next_sequence: 1, dropped_events: 0, entries: [], events: [] } }

  around do |example|
    with_tmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  before do
    File.write(boot_id_path, "#{boot_id}\n")
    File.write(support_path, "1\n")
    File.write(path, JSON.generate(empty_state))
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  def entry(pool = 'tank', id = 'ct1', time = 21.5)
    { pool:, id:, first_running_boottime_seconds: time, last_state: nil, last_observation: nil }
  end

  def write_entries(entries)
    File.write(path, JSON.generate(empty_state.merge(entries:)))
  end

  it 'loads a valid empty history without enrolling from daemon startup' do
    history.load

    expect(history.export).to eq(
      schema_version: 1, boot_id:, available: true, reason: nil, entries: [],
      max_events: 1000, dropped_events: 0, truncated: false, events: []
    )
  end

  it 'atomically persists the first observation and keeps pool-qualified identity' do
    history.load
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_BOOTTIME).and_return(21.5, 42.0)

    expect(history.record('tank', 'ct1', :running)).to be(true)
    expect(history.record('tank', 'ct1', :running)).to be(true)
    expect(history.record('other', 'ct1', :running)).to be(true)

    expect(history.export[:entries]).to eq([entry('other', 'ct1', 42.0), entry].map { |row| row.merge(last_state: 'running') })
    expect(File.stat(path).mode & 0o777).to eq(0o600)
    expect(JSON.parse(File.read(path), symbolize_names: true)[:entries]).to eq(history.export[:entries])
    expect(Dir.children(@dir).sort).to eq(%w[container-state-history.json boot-id support].sort)
  end

  it 'resumes observations after daemon restart even when containers/pools are gone' do
    history.load
    history.record('tank', 'ct1', :running)
    saved = history.export
    restarted = described_class.new(path:, boot_id_path:, support_path:)
    restarted.load

    expect(restarted.export).to eq(saved)
  end

  it 'does not let callers mutate the retained history' do
    write_entries([entry])
    history.load
    exported = history.export
    exported[:entries][0][:id] = 'changed'
    exported[:entries].clear

    expect(history.export[:entries]).to eq([entry])
  end

  it 'serializes concurrent first observations without dropping or duplicating rows' do
    history.load
    threads = 20.times.map do |i|
      Thread.new do
        2.times { history.record('tank', "ct#{i}", :running) }
      end
    end
    threads.each(&:join)

    expect(history.export[:available]).to be(true)
    expect(history.export[:entries].size).to eq(20)
    expect(JSON.parse(File.read(path))['entries'].size).to eq(20)
  end

  it 'awaits reboot only when both the file and booted-system support are absent' do
    File.unlink(path)
    File.unlink(support_path)
    history.load

    expect(history.export).to include(available: false, reason: 'awaiting_reboot', entries: [])
    expect(history.record('tank', 'ct1', :running)).to be(false)
    expect(File).not_to exist(path)
  end

  it 'reports lost state on a feature-capable boot and never recreates it' do
    File.unlink(path)
    history.load

    expect(history.export).to include(available: false, reason: 'state_missing', entries: [])
    expect(history.record('tank', 'ct1', :running)).to be(false)
    expect(File).not_to exist(path)
  end

  [
    '{',
    '[]',
    JSON.generate(schema_version: 2, boot_id: '00000000-0000-4000-8000-000000000001', entries: []),
    JSON.generate(schema_version: 1.0, boot_id: '00000000-0000-4000-8000-000000000001', entries: []),
    JSON.generate(schema_version: 1, boot_id: nil, entries: []),
    JSON.generate(schema_version: 1, boot_id: 'invalid', entries: [])
  ].each do |invalid|
    it "rejects malformed/unsupported state #{invalid.inspect}" do
      File.write(path, invalid)
      File.unlink(support_path)
      history.load

      expect(history.export).to include(available: false, reason: 'state_invalid', entries: [])
      expect(history.record('tank', 'ct1', :running)).to be(false)
      expect(File.read(path)).to eq(invalid)
    end
  end

  [
    { pool: '../tank' }, { id: 1 }, { id: '' }, { id: 'ct.id' }, { id: 'ct:id' },
    { id: 'a' * 101 }, { id: "ct\n" }, { first_running_boottime_seconds: -1 },
    { first_running_boottime_seconds: true }, { last_state: 'RUNNING' },
    { last_state: 'a' * 33 }, { last_state: false },
    { first_running_boottime_seconds: nil, last_observation: 'running' }
  ].each do |changes|
    it "rejects invalid summary #{changes.inspect}" do
      write_entries([entry.merge(changes)])
      history.load

      expect(history.export).to include(available: false, reason: 'state_invalid', entries: [])
    end
  end

  it 'rejects duplicate identity instead of treating it as complete evidence' do
    write_entries([entry, entry('tank', 'ct1', 50)])
    history.load

    expect(history.export).to include(available: false, reason: 'state_invalid', entries: [])
  end

  it 'rejects a previous boot instead of importing its successful observations' do
    File.write(path, JSON.generate(empty_state.merge(boot_id: other_boot_id, entries: [entry])))
    history.load

    expect(history.export).to include(available: false, reason: 'boot_id_mismatch', entries: [])
  end

  it 'accepts the fresh boot-hook record after a real reboot' do
    write_entries([entry])
    history.load
    File.write(boot_id_path, "#{other_boot_id}\n")
    File.write(path, JSON.generate(empty_state.merge(boot_id: other_boot_id)))
    restarted = described_class.new(path:, boot_id_path:, support_path:)
    restarted.load

    expect(restarted.export).to include(boot_id: other_boot_id, available: true, entries: [])
  end

  it 'latches failed persistence without changing the old atomic file or breaking control' do
    history.load
    allow(File).to receive(:rename).and_raise(Errno::ENOSPC)

    expect(history.record('tank', 'ct1', :running)).to be(false)
    expect(history.export).to include(available: false, reason: 'persistence_failed', entries: [])
    expect(JSON.parse(File.read(path))['entries']).to eq([])
    allow(File).to receive(:rename).and_call_original
    history.load
    expect(history.record('tank', 'ct1', :running)).to be(false)

    restarted = described_class.new(path:, boot_id_path:, support_path:)
    restarted.load
    expect(restarted.export).to include(available: false, reason: 'persistence_failed', entries: [])
  end

  it 'renames the prior record to a sticky sentinel when writing a new snapshot fails' do
    history.load
    allow(history).to receive(:persist).and_raise(IOError, 'write failed')

    expect(history.record('tank', 'ct1', :running)).to be(false)
    expect(File).not_to exist(path)
    failure_path = File.join(@dir, 'container-state-history.failed.json')
    expect(File).to exist(failure_path)
    expect(JSON.parse(File.read(failure_path))['entries']).to eq([])

    # Restoring an older valid file cannot bypass the known failed observation.
    File.write(path, JSON.generate(empty_state))
    restarted = described_class.new(path:, boot_id_path:, support_path:)
    restarted.load
    expect(restarted.export).to include(available: false, reason: 'persistence_failed', entries: [])
  end

  it 'treats dangling sentinel paths as retained failure ahead of a valid normal record' do
    File.symlink(File.join(@dir, 'absent'), File.join(@dir, 'container-state-history.failed.json'))
    history.load

    expect(history.export).to include(available: false, reason: 'persistence_failed', entries: [])
    expect(history.record('tank', 'ct1', :running)).to be(false)
  end

  it 'rechecks sentinel presence during uptime and never replaces existing failure evidence' do
    history.load
    failure_path = File.join(@dir, 'container-state-history.failed.json')
    File.write(failure_path, 'retained evidence')

    expect(history.record('tank', 'ct1', :running)).to be(false)
    expect(history.export).to include(available: false, reason: 'persistence_failed', entries: [])
    expect(File.read(failure_path)).to eq('retained evidence')
    expect(JSON.parse(File.read(path))['entries']).to eq([])
  end

  it 'never returns successful history when sentinel inspection fails' do
    allow(File).to receive(:lstat).and_call_original
    allow(File).to receive(:lstat).with(File.join(@dir, 'container-state-history.failed.json')).and_raise(Errno::EACCES)
    history.load

    expect(history.export).to include(available: false, reason: 'state_invalid', entries: [])
  end

  it 'invalidates the old record if both renaming and sentinel creation fail' do
    history.load
    allow(history).to receive(:persist).and_raise(IOError, 'write failed')
    allow(File).to receive(:rename).and_raise(Errno::EACCES)
    allow(File).to receive(:open).and_call_original
    allow(File).to receive(:open).with(
      File.join(@dir, 'container-state-history.failed.json'), File::WRONLY | File::CREAT | File::EXCL, 0o600
    ).and_raise(Errno::ENOSPC)

    expect(history.record('tank', 'ct1', :running)).to be(false)
    expect(File).not_to exist(path)
    restarted = described_class.new(path:, boot_id_path:, support_path:)
    restarted.load
    expect(restarted.export).to include(available: false, reason: 'state_missing', entries: [])
  end

  it 'logs the persistence limit if all filesystem mutations fail' do
    history.load
    allow(history).to receive(:persist).and_raise(IOError, 'write failed')
    allow(File).to receive(:rename).and_raise(Errno::EACCES)
    allow(File).to receive(:open).and_raise(Errno::EACCES)
    allow(File).to receive(:unlink).and_raise(Errno::EACCES)

    expect(history.record('tank', 'ct1', :running)).to be(false)
    expect(history.export).to include(available: false, reason: 'persistence_failed')
    expect(OsCtl::Lib::Logger).to have_received(:log).with(
      :warn, /Unable to retain failure across daemon restart; history may be incomplete/
    )
  end

  it 'detects missing state during uptime without treating in-memory history as persisted' do
    history.load
    File.unlink(path)

    expect(history.export).to include(available: false, reason: 'state_missing', entries: [])
  end

  it 'detects damaged state during uptime without silently overwriting it' do
    history.load
    File.write(path, '{')

    expect(history.export).to include(available: false, reason: 'state_invalid', entries: [])
    expect(history.record('tank', 'ct1', :running)).to be(false)
    expect(File.read(path)).to eq('{')
  end

  it 'keeps full-boot proof after cap1 evicts the running event and across restart' do
    history.load(max_events: 1)
    history.record('tank', 'ct1', :running)
    first = history.export(view: 'ever_running')
    history.record('tank', 'ct1', :stopped)
    restarted = described_class.new(path:, boot_id_path:)
    restarted.load(max_events: 1)

    expect(restarted.export(view: 'ever_running')).to eq(first)
    expect(restarted.export).to include(max_events: 1, dropped_events: 1, truncated: true)
    expect(restarted.export[:events]).to contain_exactly(include(sequence: 2, state: 'stopped'))
    restarted.record('tank', 'ct1', :stopped)
    expect(restarted.export).to eq(history.export)
  end

  it 'atomically trims on a lower cap and cannot recover evicted events on increase' do
    history.load(max_events: 3)
    %i[starting running stopped].each { |state| history.record('tank', 'ct1', state) }
    smaller = described_class.new(path:, boot_id_path:)
    smaller.load(max_events: 1)
    larger = described_class.new(path:, boot_id_path:)
    larger.load(max_events: 5)

    expect(smaller.export).to include(dropped_events: 2, truncated: true)
    expect(larger.export[:events]).to eq(smaller.export[:events])
    expect(larger.export[:entries]).to eq(smaller.export[:entries])
    expect(JSON.parse(File.read(path))).to include('next_sequence' => 4, 'dropped_events' => 2)
  end

  it 'latches an atomic trim failure across restart' do
    history.load
    %i[running stopped].each { |state| history.record('tank', 'ct1', state) }
    smaller = described_class.new(path:, boot_id_path:)
    allow(smaller).to receive(:persist).and_raise(IOError, 'trim failed')
    smaller.load(max_events: 1)
    restarted = described_class.new(path:, boot_id_path:)
    restarted.load

    expect(smaller.export).to include(available: false, reason: 'persistence_failed')
    expect(restarted.export(view: 'ever_running')).to include(available: false, reason: 'persistence_failed')
  end

  it 'deduplicates each kind independently across restarts and preserves first proof' do
    history.load
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_BOOTTIME).and_return(21.5, 22.0, 23.0)
    history.record('tank', 'ct1', :error)
    history.record('tank', 'ct1', :running, kind: :observation)
    restarted = described_class.new(path:, boot_id_path:)
    restarted.load
    restarted.record('tank', 'ct1', :error)
    restarted.record('tank', 'ct1', :running, kind: :observation)
    restarted.record('tank', 'ct1', :running)

    expect(restarted.export[:events].map { |e| [e[:sequence], e[:kind], e[:state]] }).to eq(
      [[1, 'state', 'error'], [2, 'observation', 'running'], [3, 'state', 'running']]
    )
    expect(restarted.export[:entries]).to contain_exactly(include(first_running_boottime_seconds: 22.0))
  end

  it 'always skips initial unprobed running even after previous actual running' do
    history.load
    history.record('tank', 'ct1', :running, initial: true)
    expect(history.export[:events]).to eq([])
    history.record('tank', 'ct1', :running)
    history.record('tank', 'ct1', :stopped)
    saved = history.export
    history.record('tank', 'ct1', :running, initial: true)

    expect(history.export).to eq(saved)
  end

  it 'filters saved identities without changing global counters or compact wire keys' do
    history.load(max_events: 1)
    history.record('tank', 'ct1', :running)
    history.record('other', 'ct2', :stopped)

    expect(history.export(pool: 'tank', id: 'ct1')).to include(dropped_events: 1, truncated: true, events: [])
    expect(history.export(view: 'ever_running', pool: 'tank')).to match(
      schema_version: 1, boot_id:, available: true, reason: nil,
      entries: [{ pool: 'tank', id: 'ct1', first_running_boottime_seconds: a_kind_of(Numeric) }]
    )
  end

  [{ view: 'unknown' }, { id: 'ct1' }, { pool: false }, { pool: 'tank', id: false }, { pool: '../tank' }, { pool: 'tank', id: 'ct.id' }].each do |options|
    it "rejects invalid query #{options.inspect} without damaging history" do
      history.load
      expect { history.export(**options) }.to raise_error(ArgumentError)
      expect(history.export[:available]).to be(true)
    end
  end

  it 'serializes sequence and clock assignment across concurrent changes' do
    history.load(max_events: 100)
    threads = 20.times.map do |i|
      Thread.new do
        history.record('tank', "c#{i}", :running)
        history.record('tank', "c#{i}", :stopped)
      end
    end
    threads.each(&:join)
    events = history.export[:events]

    expect(events.map { |e| e[:sequence] }).to eq((1..40).to_a)
    expect(events.map { |e| e[:boottime_seconds] }).to eq(events.map { |e| e[:boottime_seconds] }.sort)
    restarted = described_class.new(path:, boot_id_path:)
    restarted.load(max_events: 100)
    expect(restarted.export).to eq(history.export)
  end

  [true, '1', 1.5, 0, -1, 10_001].each do |value|
    it "rejects invalid cap #{value.inspect}" do
      expect { history.load(max_events: value) }.to raise_error(ArgumentError)
    end
  end

  %i[sequence time kind state summary missing_summary proof counter extra_key].each do |damage|
    it "rejects corrupted timeline #{damage}" do
      history.load
      history.record('tank', 'ct1', :running)
      data = JSON.parse(File.read(path))
      event = data['events'].first
      case damage
      when :sequence then event['sequence'] = 2
      when :time then event['boottime_seconds'] = -1
      when :kind then event['kind'] = 'requested'
      when :state then event['state'] = 'RUNNING'
      when :summary then data['entries'].first['last_state'] = 'stopped'
      when :missing_summary then data['entries'] = []
      when :proof then data['entries'].first['first_running_boottime_seconds'] = nil
      when :counter then data['dropped_events'] = 1
      when :extra_key then event['extra'] = true
      end
      File.write(path, JSON.generate(data))
      restarted = described_class.new(path:, boot_id_path:)
      restarted.load

      expect(restarted.export).to include(available: false, reason: 'state_invalid', dropped_events: nil, truncated: nil)
    end
  end

  it 'initializes and clears the failure sentinel only through the actual boot script' do
    failure_path = File.join(@dir, 'container-state-history.failed.json')
    File.write(failure_path, 'previous failure')
    File.write(path, '{')
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with('/proc/sys/kernel/random/boot_id').and_return(boot_id)
    allow(FileUtils).to receive(:mkdir_p).with('/run/osctl', mode: 0o711)
    allow(Tempfile).to receive(:create).and_wrap_original do |method, names, _directory, &block|
      method.call(names, @dir, &block)
    end
    allow(File).to receive(:rename).and_wrap_original do |method, source, _target|
      method.call(source, path)
    end
    allow(FileUtils).to receive(:rm_f).with('/run/osctl/container-state-history.failed.json').and_wrap_original do |method, _target|
      method.call(failure_path)
    end
    load File.expand_path('../../../os/modules/osctl/container_state_history.rb', __dir__)
    history.load

    expect(history.export).to include(available: true, entries: [], events: [], dropped_events: 0)
    expect(File).not_to exist(failure_path)
    expect(File.stat(path).mode & 0o777).to eq(0o600)
  end

  it 'does not retain mutable state arguments supplied by callers' do
    history.load
    state = +'running'
    kind = +'state'
    history.record('tank', 'ct1', state, kind:)
    state.replace('stopped')
    kind.replace('observation')

    expect(history.export[:available]).to be(true)
    expect(history.export[:events]).to contain_exactly(include(kind: 'state', state: 'running'))
  end
end

# rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/InstanceVariable
