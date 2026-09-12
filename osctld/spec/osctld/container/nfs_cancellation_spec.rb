# frozen_string_literal: true

# Replace privileged namespace operations; the worker protocol still uses real
# children and descriptors. VM tests exercise the actual namespace syscalls.
# rubocop:disable RSpec/SubjectStub

require 'osctld/container/run_id'
require 'osctld/container/nfs_cancellation'

RSpec.describe OsCtld::Container::NfsCancellation do
  subject(:cancellation) { described_class.new(ct, run_id:, state_root: File.join(root, 'state')) }

  let(:ct) { Struct.new(:id, :ident, :cgroup_path).new('ct1', 'tank:ct1', 'osctl/ct.ct1/user-owned') }
  let(:run_id) { OsCtld::Container::RunId.new(pool_name: 'tank', container_id: 'ct1', timestamp: 123.5) }
  let(:root) { Dir.mktmpdir('nfs-cancel-spec-') }
  let(:control) { File.join(root, 'shutdown_tree') }

  before do
    stub_const('OsCtld::Container::NfsCancellation::TREE_CONTROL', control)
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  after do
    cancellation.instance_variable_get(:@worker)&.join(2)
    cancellation.close
    FileUtils.remove_entry(root)
  end

  def arm
    File.write(control, "0\n")
    cancellation.instance_variable_set(:@owner, File.open('/proc/self/ns/user'))
    cancellation.instance_variable_set(:@netns, File.open('/proc/self/ns/net'))
    state = cancellation.instance_variable_get(:@state)
    allow(state).to receive(:load).and_return(nil)
    allow(state).to receive(:update)
    allow(state).to receive(:claim_worker) do
      File.open(File.join(root, 'worker.lock'), File::RDWR | File::CREAT, 0o600).tap do |io|
        io.flock(File::LOCK_EX)
      end
    end
    state
  end

  def run_worker(&operation)
    arm
    allow(cancellation).to receive(:cancel_namespace, &operation)
    cancellation.send(
      :cancel_in_worker,
      cancellation.instance_variable_get(:@owner),
      cancellation.instance_variable_get(:@netns)
    )
  end

  it 'does not create a worker or wait on an unsupported kernel' do
    arm
    File.unlink(control)
    allow(OsCtld::SwitchUser).to receive(:fork).and_call_original
    allow(Thread).to receive(:new).and_call_original

    expect(cancellation.abort(wait: 5)).to eq(0)
    expect(OsCtld::SwitchUser).not_to have_received(:fork)
    expect(Thread).not_to have_received(:new)
  end

  it 'does not write legacy or single-namespace controls' do
    arm
    File.unlink(control)
    %w[shutdown 0:12/shutdown server-4/shutdown].each do |name|
      path = File.join(root, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "0\n")
    end
    expect(cancellation.abort(wait: 5)).to eq(0)
    %w[shutdown 0:12/shutdown server-4/shutdown].each do |name|
      expect(File.read(File.join(root, name))).to eq("0\n")
    end
  end

  it 'detects support appearing after an earlier unsupported request' do
    arm
    File.unlink(control)
    expect(cancellation.abort).to eq(0)
    File.write(control, "0\n")
    allow(cancellation).to receive(:cancel_namespace).and_return(1)
    expect(cancellation.abort(wait: 2)).to eq(1)
  end

  it 'requires authenticated retained namespaces even on a capable kernel' do
    File.write(control, "0\n")
    expect(cancellation.abort).to eq(0)
    expect(cancellation.instance_variable_get(:@worker)).to be_nil
  end

  it 'does not adopt a namespace from an ordinary monitor capture' do
    allow(cancellation).to receive(:with_process).and_call_original
    cancellation.capture(Process.pid)
    expect(cancellation).not_to have_received(:with_process)
  end

  it 'rejects the host user namespace even from a trusted capture' do
    allow(cancellation).to receive(:member?).and_return(true)
    state = cancellation.instance_variable_get(:@state)
    allow(state).to receive(:pin)
    cancellation.capture(Process.pid, trusted: true)
    expect(state).not_to have_received(:pin)
    expect(cancellation.instance_variable_get(:@owner)).to be_nil
  end

  it 'persists terminal intent before starting the worker' do
    state = arm
    allow(cancellation).to receive(:cancel_namespace).and_return(1)
    # Ordering is the assertion: terminal intent must precede the new worker.
    expect(state).to receive(:update).with({ 'terminal' => true }, deadline: anything).ordered # rubocop:disable RSpec/MessageSpies
    expect(Thread).to receive(:new).ordered.and_call_original # rubocop:disable RSpec/MessageSpies
    expect(cancellation.abort(wait: 2)).to eq(1)
  end

  it 'bounds the head start and coalesces concurrent requests' do
    arm
    allow(cancellation).to receive(:cancel_namespace) {
      sleep(0.5)
      1
    }
    allow(OsCtld::SwitchUser).to receive(:fork).and_call_original
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(cancellation.abort(wait: 0.01)).to eq(0)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).to be < 0.25
    cancellation.abort(wait: 2)
    cancellation.abort(wait: 2)
    expect(OsCtld::SwitchUser).to have_received(:fork).once
    expect(cancellation.instance_variable_get(:@completed)).to be(true)
  end

  it 'does not hold its mutex during the cancellation worker wait' do
    arm
    allow(cancellation).to receive(:cancel_namespace) {
      sleep(0.1)
      1
    }
    cancellation.abort
    expect { cancellation.instance_variable_get(:@mutex).lock(0) }.not_to raise_error
    cancellation.instance_variable_get(:@mutex).unlock
  end

  it 'returns from a contended object lock within the cancellation head start' do
    arm
    mutex = cancellation.instance_variable_get(:@mutex)
    ready = Queue.new
    release = Queue.new
    holder = Thread.new do
      mutex.synchronize do
        ready << true
        release.pop
      end
    end
    pop_with_timeout(ready)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(cancellation.abort(wait: 0.05)).to eq(0)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.3
    expect(cancellation.instance_variable_get(:@worker)).to be_nil
  ensure
    release << true
    holder&.join
  end

  it 'reports worker errors without raising through a kill or monitor request' do
    arm
    allow(cancellation).to receive(:cancel_namespace).and_raise(IOError, 'write failed')
    expect(cancellation.abort(wait: 2)).to eq(0)
    expect(cancellation.instance_variable_get(:@completed)).to be(false)
    expect(OsCtl::Lib::Logger).to have_received(:log).with(:warn, /write failed/)
  end

  it 'cannot reopen a closed run through a stale monitor reference' do
    cancellation.close
    allow(cancellation).to receive(:with_process).and_call_original
    cancellation.capture(Process.pid, trusted: true)
    expect(cancellation).not_to have_received(:with_process)
    expect(cancellation.abort_if_exiting).to eq(0)
  end

  it 'checks payload membership for both cgroup versions without accepting siblings' do
    %w[
      0::/osctl/ct.ct1/user-owned/lxc.payload.ct1
      5:freezer:/osctl/ct.ct1/user-owned/lxc.payload.ct1/service
      5:devices,freezer:/osctl/ct.ct1/user-owned/lxc.payload.ct1
    ].each do |line|
      File.write(File.join(root, 'cgroup'), "#{line}\n")
      expect(cancellation.send(:member?, root)).to be(true)
    end
    %w[
      0::/osctl/ct.ct1/user-owned/lxc.payload.ct10
      0::/osctl/ct.ct1/user-owned/lxc.monitor.ct1
      0::/osctl/ct.ct2/user-owned/lxc.payload.ct2
      2:cpu:/osctl/ct.ct1/user-owned/lxc.payload.ct1
      malformed
    ].each do |line|
      File.write(File.join(root, 'cgroup'), "#{line}\n")
      expect(cancellation.send(:member?, root)).to be(false)
    end
  end

  it 'compares both device and inode for namespace identity' do
    io = instance_double(IO, stat: Struct.new(:dev, :ino).new(4, 8))
    expect(cancellation.send(:same_namespace?, io, Struct.new(:dev, :ino).new(4, 8))).to be(true)
    expect(cancellation.send(:same_namespace?, io, Struct.new(:dev, :ino).new(5, 8))).to be(false)
  end

  describe 'worker protocol' do
    it 'returns the completed count' do
      expect(run_worker { 1 }).to eq(1)
    end

    it 'propagates child errors to the worker supervisor' do
      expect { run_worker { raise IOError, 'write failed' } }.to raise_error(RuntimeError, /write failed/)
    end

    it 'rejects an incomplete response' do
      expect { run_worker { exit! } }.to raise_error(JSON::ParserError)
    end

    it 'limits the response size' do
      expect { run_worker { raise 'x' * 70_000 } }.to raise_error(RuntimeError, /output is too large/)
    end

    it 'bounds the worker lifetime and reaps only its own child' do
      stub_const('OsCtld::Container::NfsCancellation::WORKER_TIMEOUT', 0.05)
      reapers = []
      allow(Process).to receive(:detach).and_wrap_original do |original, pid|
        original.call(pid).tap { |thread| reapers << thread }
      end
      expect { run_worker { sleep(60) } }.to raise_error(described_class::WorkerTimeout)
      expect(reapers.length).to eq(1)
      expect(reapers.first.join(2)).not_to be_nil
      expect(reapers.first.value.termsig).to eq(Signal.list.fetch('KILL'))
    end
  end

  describe 'original init identity' do
    def write_stat(path, flags: 0, start_time: '100')
      fields = Array.new(20, '0')
      fields[0] = 'S'
      fields[6] = flags.to_s
      fields[19] = start_time
      File.write(path, "123 (init (test)) #{fields.join(' ')}\n")
    end

    def with_init
      proc_root = File.join(root, 'proc')
      FileUtils.mkdir_p(File.join(proc_root, 'self'))
      File.symlink('/proc/self/fd', File.join(proc_root, 'self/fd'))
      path = File.join(proc_root, '123')
      FileUtils.mkdir_p(File.join(path, 'task/123'))
      File.write(File.join(path, 'status'), "NSpid:\t123\t1\n")
      File.write(File.join(path, 'cgroup'), "0::/osctl/ct.ct1/user-owned/lxc.payload.ct1\n")
      write_stat(File.join(path, 'stat'))
      write_stat(File.join(path, 'task/123/stat'))
      scanner = described_class.new(ct, run_id:, proc_root:, state_root: File.join(root, 'scan-state'))
      allow(scanner).to receive(:abort).and_return(1)
      File.open(path) { |dir| scanner.send(:retain_init, path, dir) }
      yield scanner, path
    ensure
      scanner&.close
    end

    it 'detects PF_EXITING before the LXC stopping notification' do
      with_init do |scanner, path|
        expect(scanner.abort_if_exiting).to eq(0)
        write_stat(File.join(path, 'task/123/stat'), flags: 4)
        expect(scanner.abort_if_exiting).to eq(1)
      end
    end

    it 'does not cancel when only the init thread-group leader exits' do
      with_init do |scanner, path|
        write_stat(File.join(path, 'task/123/stat'), flags: 4)
        FileUtils.mkdir_p(File.join(path, 'task/124'))
        write_stat(File.join(path, 'task/124/stat'))
        expect(scanner.abort_if_exiting).to eq(0)
        write_stat(File.join(path, 'task/124/stat'), flags: 4)
        expect(scanner.abort_if_exiting).to eq(1)
      end
    end

    it 'uses retained proc identity even after a numeric PID path is replaced' do
      with_init do |scanner, path|
        File.rename(path, "#{path}-old")
        FileUtils.mkdir_p(File.join(path, 'task/123'))
        write_stat(File.join(path, 'stat'), flags: 4, start_time: '200')
        write_stat(File.join(path, 'task/123/stat'), flags: 4, start_time: '200')
        expect(scanner.abort_if_exiting).to eq(0)
        FileUtils.remove_entry(File.join("#{path}-old", 'task'))
        expect(scanner.abort_if_exiting).to eq(1)
      end
    end

    it 'rejects a reused PID when reopening saved init identity' do
      with_init do |scanner, path|
        scanner.instance_variable_get(:@init_proc).close
        scanner.instance_variable_set(:@init_proc, nil)
        write_stat(File.join(path, 'stat'), start_time: '200')
        scanner.send(:restore_init)
        expect(scanner.instance_variable_get(:@init_proc)).to be_nil
      end
    end

    it 'does not mistake a hook process for init' do
      File.write(File.join(root, 'status'), "NSpid:\t123\t8\n")
      File.open(root) { |dir| cancellation.send(:retain_init, root, dir) }
      expect(cancellation.abort_if_exiting).to eq(0)
    end
  end
end
# rubocop:enable RSpec/SubjectStub
