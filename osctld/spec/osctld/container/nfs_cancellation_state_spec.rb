# frozen_string_literal: true

require 'osctld/container/run_id'
require 'osctld/container/nfs_cancellation_state'

RSpec.describe OsCtld::Container::NfsCancellationState do
  let(:run_id) { OsCtld::Container::RunId.new(pool_name: 'tank', container_id: 'ct1', timestamp: 123.5) }
  let(:payload) { '/osctl/tank/ct.ct1/user-owned/lxc.payload.ct1' }
  let(:root) { Dir.mktmpdir('nfs-state-spec-') }
  let(:state) { described_class.new(run_id, payload, root: store_root, boot_id: 'test-boot') }
  let(:sys) { instance_double(OsCtl::Lib::Sys) }

  # Hard links model the inode retention of bind mounts without host mounts.
  # Namespace type/ownership validation is covered separately by the caller.
  before do
    allow(OsCtl::Lib::Sys).to receive(:new).and_return(sys)
    allow(sys).to receive(:bind_mount) do |src, dst|
      File.unlink(dst)
      File.link(File.realpath(src), dst)
    end
    allow(sys).to receive(:unmount).and_return(0)
  end

  after { FileUtils.remove_entry(root) }

  def store_root
    File.join(root, 'runs')
  end

  def pin
    File.open(File.join(root, 'owner'), File::RDWR | File::CREAT, 0o600) do |owner|
      File.open(File.join(root, 'net'), File::RDWR | File::CREAT, 0o600) do |net|
        state.pin(owner, net)
      end
    end
  end

  it 'retains namespace identity after the original descriptors and paths disappear' do
    record = pin
    File.unlink(File.join(root, 'owner'))
    File.unlink(File.join(root, 'net'))
    restored = described_class.new(run_id, payload, root: store_root, boot_id: 'test-boot')

    expect(restored.load).to eq(record)
    %w[user net].each do |name|
      io = restored.open_namespace(name, record.fetch('namespaces').fetch(name))
      expect([io.stat.dev, io.stat.ino]).to eq(record['namespaces'][name])
      io.close
    end
  end

  it 'preserves terminal intent and init identity across reloads' do
    pin
    init = { 'pid' => 456, 'start_time' => '789' }
    state.update({ 'init' => init, 'terminal' => true })
    restored = described_class.new(run_id, payload, root: store_root, boot_id: 'test-boot')

    expect(restored.load).to include('init' => init, 'terminal' => true)
    restored.update({ 'completed' => true })
    expect(state.load).to include('init' => init, 'terminal' => true, 'completed' => true)
  end

  it 'rejects a record from another boot' do
    pin
    restored = described_class.new(run_id, payload, root: store_root, boot_id: 'other-boot')
    expect { restored.load }.to raise_error(described_class::InvalidState, /another run or boot/)
  end

  it 'gives a later run of the same container a separate state directory' do
    pin
    next_run = OsCtld::Container::RunId.new(pool_name: 'tank', container_id: 'ct1', timestamp: 124.5)
    replacement = described_class.new(next_run, payload, root: store_root, boot_id: 'test-boot')
    expect(replacement.dir).not_to eq(state.dir)
    expect(replacement.load).to be_nil
  end

  it 'rejects substituted namespace pins' do
    record = pin
    File.unlink(File.join(state.dir, 'net'))
    File.write(File.join(state.dir, 'net'), 'replacement')
    expect { state.open_namespace('net', record['namespaces']['net']) }
      .to raise_error(described_class::InvalidState, /does not match/)
  end

  it 'does not publish usable handles until both pins exist and can resume preparation' do
    allow(sys).to receive(:bind_mount).with(anything, File.join(state.dir, 'net')).and_raise(Errno::EIO)
    expect { pin }.to raise_error(Errno::EIO)
    expect(state.load).not_to have_key('namespaces')

    allow(sys).to receive(:bind_mount).with(anything, File.join(state.dir, 'net')) do |src, dst|
      File.unlink(dst)
      File.link(File.realpath(src), dst)
    end
    expect(pin.fetch('namespaces').keys).to contain_exactly('user', 'net')
  end

  it 'retires interrupted preparation without leaving namespace pins behind' do
    allow(sys).to receive(:bind_mount).with(anything, File.join(state.dir, 'net')).and_raise(Errno::EIO)
    expect { pin }.to raise_error(Errno::EIO)
    expect(state.retire).to be(true)
    expect(File.exist?(state.dir)).to be(false)
  end

  it 'keeps retired pins while a worker owns the run and cleans them after release' do
    pin
    worker_lock = state.claim_worker
    expect(state.claim_worker).to be_nil
    expect(state.retire).to be(false)
    expect(state.load).to include('retired' => true)
    worker_lock.close

    expect(state.cleanup).to be(true)
    expect(File.exist?(state.dir)).to be(false)
    expect(state.retire).to be(true)
  end

  it 'does not remove a live run during reconciliation' do
    pin
    expect(state.cleanup).to be(false)
    expect(File.exist?(state.dir)).to be(true)
  end

  it 'rejects a symlink in place of the run directory' do
    Dir.mkdir(store_root, 0o700)
    File.symlink(root, state.dir)
    expect { pin }.to raise_error(described_class::InvalidState, /unsafe/)
  end

  it 'does not lose concurrent updates from a worker and the daemon' do
    pin
    threads = [
      Thread.new { state.update({ 'completed' => true }) },
      Thread.new { state.update({ 'retired' => true }) }
    ]
    threads.each(&:join)
    expect(state.load).to include('completed' => true, 'retired' => true)
  end

  it 'bounds metadata lock contention without changing persisted state' do
    pin
    File.open(File.join(state.dir, 'lock'), File::RDWR) do |holder|
      holder.flock(File::LOCK_EX)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect do
        state.update({ 'terminal' => true }, deadline: started + 0.05)
      end.to raise_error(described_class::LockTimeout)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.3
      expect(state.load['terminal']).to be_nil
    end
    state.update({ 'terminal' => true }, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC))
    expect(state.load['terminal']).to be(true)
  end
end
